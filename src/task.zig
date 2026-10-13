const std = @import("std");
const builtin = @import("builtin");
pub const memory = @import("memory.zig");
pub const ring = @import("ring.zig");

pub const MAX_TASKS: usize = 64;
pub const DEFAULT_STACK_SIZE: usize = 16 * 1024; // 16 KiB per task stack
pub const STACK_PAGE_COUNT: usize = (DEFAULT_STACK_SIZE + memory.PAGE_SIZE - 1) / memory.PAGE_SIZE;

/// State of a green thread in the single flat address space
pub const TaskState = enum(u8) {
    unused = 0,
    ready = 1,
    running = 2,
    suspended = 3,
    terminated = 4,
};

/// Saved register context for cooperative green threads on AArch64.
/// Only general-purpose registers x19-x30 and SP are callee-saved across switches.
/// Page tables and translation registers are untouched (Law of the Single Flat Space).
pub const TaskContext = struct {
    // Callee-saved general-purpose registers (offset 0 .. 95)
    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
    x29: u64 = 0, // Frame Pointer (FP)
    x30: u64 = 0, // Link Register (LR / Return Address)

    // Stack pointer (offset 96)
    sp: u64 = 0,

    // Argument passed to task entry (offset 104)
    arg: u64 = 0,

    // SIMD / FP callee-saved registers (d8 - d15, offset 112 .. 175)
    d8: u64 = 0,
    d9: u64 = 0,
    d10: u64 = 0,
    d11: u64 = 0,
    d12: u64 = 0,
    d13: u64 = 0,
    d14: u64 = 0,
    d15: u64 = 0,
};

pub const TaskId = u32;
pub const TaskFn = *const fn (u64) void;

/// Green thread control block residing in the unified 64-bit flat address space
pub const Task = struct {
    id: TaskId = 0,
    state: TaskState = .unused,
    context: TaskContext = .{},
    stack_base_phys: u64 = 0,
    stack_size: usize = DEFAULT_STACK_SIZE,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    entry: ?TaskFn = null,
    arg: u64 = 0,
    yield_count: u64 = 0,
    managed_stack_pages: [STACK_PAGE_COUNT]ring.ManagedPage = [_]ring.ManagedPage{ring.ManagedPage.invalid} ** STACK_PAGE_COUNT,
    stack_page_count: usize = 0,

    pub fn setName(self: *Task, name_slice: []const u8) void {
        const len = @min(name_slice.len, self.name.len);
        @memcpy(self.name[0..len], name_slice[0..len]);
        self.name_len = len;
    }

    pub fn getName(self: *const Task) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Scheduler managing cooperative green threads sharing the flat address space
pub const Scheduler = struct {
    tasks: [MAX_TASKS]Task = [_]Task{.{}} ** MAX_TASKS,
    current_task_id: ?TaskId = null,
    next_task_id: TaskId = 1,
    task_count: usize = 0,
    initialized: bool = false,
    switch_count: u64 = 0,

    // Static stacks for mock/host testing if needed
    static_stacks: [MAX_TASKS][DEFAULT_STACK_SIZE]u8 align(16) = undefined,

    pub fn init(self: *Scheduler) void {
        self.current_task_id = null;
        self.next_task_id = 1;
        self.task_count = 0;
        self.switch_count = 0;

        for (&self.tasks) |*t| {
            t.* = .{};
        }

        // Slot 0 is reserved for the primary/kernel thread
        self.tasks[0].id = 0;
        self.tasks[0].state = .running;
        self.tasks[0].setName("kernel_main");
        self.current_task_id = 0;
        self.task_count = 1;
        self.initialized = true;
    }

    pub fn getCurrentTask(self: *Scheduler) ?*Task {
        if (self.current_task_id) |id| {
            return self.getTaskById(id);
        }
        return null;
    }

    pub fn getTaskById(self: *Scheduler, id: TaskId) ?*Task {
        for (&self.tasks) |*t| {
            if (t.state != .unused and t.id == id) {
                return t;
            }
        }
        return null;
    }

    pub fn getTaskCount(self: *const Scheduler) usize {
        return self.task_count;
    }

    pub fn getSwitchCount(self: *const Scheduler) u64 {
        return self.switch_count;
    }

    /// Spawn a new task using the PhysicalMemoryManager for stack allocation
    pub fn spawn(
        self: *Scheduler,
        pmm: *memory.PhysicalMemoryManager,
        entry: TaskFn,
        arg: u64,
        name: []const u8,
    ) ?TaskId {
        // Find unused task slot
        var slot_idx: ?usize = null;
        for (&self.tasks, 0..) |*t, idx| {
            if (t.state == .unused) {
                slot_idx = idx;
                break;
            }
        }
        const idx = slot_idx orelse return null;

        // Allocate physical frames for stack
        const stack_phys = pmm.allocContiguousFrames(STACK_PAGE_COUNT, 1) orelse return null;
        const stack_top_virt = @as(usize, @intCast(stack_phys + pmm.hhdm_offset)) + DEFAULT_STACK_SIZE;

        const task_id = self.next_task_id;
        self.next_task_id += 1;

        var task = &self.tasks[idx];
        task.* = .{
            .id = task_id,
            .state = .ready,
            .stack_base_phys = stack_phys,
            .stack_size = DEFAULT_STACK_SIZE,
            .entry = entry,
            .arg = arg,
            .yield_count = 0,
            .stack_page_count = STACK_PAGE_COUNT,
        };
        task.setName(name);

        // Track allocated stack pages as ManagedPages for lifecycle management
        var p: usize = 0;
        while (p < STACK_PAGE_COUNT) : (p += 1) {
            const page_phys = stack_phys + (p * memory.PAGE_SIZE);
            task.managed_stack_pages[p] = ring.ManagedPage.initActive(page_phys);
        }

        // Initialize TaskContext for AArch64
        task.context = .{};
        // AArch64 stack pointer must be 16-byte aligned
        task.context.sp = @as(u64, @intCast(stack_top_virt & ~@as(usize, 15)));
        task.context.x30 = @as(u64, @intFromPtr(&taskEntryTrampoline));
        task.context.arg = arg;

        self.task_count += 1;
        return task_id;
    }

    /// Spawn a task in test / simulated environment using static buffers
    pub fn spawnStatic(
        self: *Scheduler,
        entry: TaskFn,
        arg: u64,
        name: []const u8,
    ) ?TaskId {
        var slot_idx: ?usize = null;
        for (&self.tasks, 0..) |*t, idx| {
            if (t.state == .unused) {
                slot_idx = idx;
                break;
            }
        }
        const idx = slot_idx orelse return null;

        const task_id = self.next_task_id;
        self.next_task_id += 1;

        const stack_top = @as(usize, @intFromPtr(&self.static_stacks[idx][0])) + DEFAULT_STACK_SIZE;

        var task = &self.tasks[idx];
        task.* = .{
            .id = task_id,
            .state = .ready,
            .stack_base_phys = 0,
            .stack_size = DEFAULT_STACK_SIZE,
            .entry = entry,
            .arg = arg,
            .yield_count = 0,
            .stack_page_count = 0,
        };
        task.setName(name);

        task.context = .{};
        task.context.sp = @as(u64, @intCast(stack_top & ~@as(usize, 15)));
        task.context.x30 = @as(u64, @intFromPtr(&taskEntryTrampoline));
        task.context.arg = arg;

        self.task_count += 1;
        return task_id;
    }

    /// Yield execution cooperatively to the next ready task.
    /// Strictly maintains Law of the Single Flat Space: switches registers only,
    /// no TTBR0/1 or TLB flushes.
    pub fn yield(self: *Scheduler) void {
        const cur_id = self.current_task_id orelse return;
        const cur_task = self.getTaskById(cur_id) orelse return;

        // Find next ready task (Round-Robin)
        var next_task: ?*Task = null;
        var start_idx: usize = 0;
        for (&self.tasks, 0..) |*t, i| {
            if (t.id == cur_id) {
                start_idx = (i + 1) % MAX_TASKS;
                break;
            }
        }

        var i: usize = 0;
        while (i < MAX_TASKS) : (i += 1) {
            const check_idx = (start_idx + i) % MAX_TASKS;
            const candidate = &self.tasks[check_idx];
            if (candidate.state == .ready) {
                next_task = candidate;
                break;
            }
        }

        const next = next_task orelse return;

        // Perform context switch
        if (cur_task.state == .running) {
            cur_task.state = .ready;
        }
        cur_task.yield_count += 1;

        next.state = .running;
        self.current_task_id = next.id;
        self.switch_count += 1;

        switchContext(&cur_task.context, &next.context);
    }

    /// Terminate current task and switch to the next ready task
    pub fn exit(self: *Scheduler, pmm: ?*memory.PhysicalMemoryManager, slab_alloc: ?*memory.slab.SlabAllocator) noreturn {
        const cur_id = self.current_task_id orelse {
            while (true) {}
        };
        const cur_task = self.getTaskById(cur_id) orelse {
            while (true) {}
        };

        cur_task.state = .terminated;
        if (self.task_count > 0) self.task_count -= 1;

        // Free stack frames when PMM is available
        if (pmm) |p| {
            if (cur_task.stack_base_phys != 0) {
                var page_i: usize = 0;
                while (page_i < cur_task.stack_page_count) : (page_i += 1) {
                    if (slab_alloc) |s| {
                        cur_task.managed_stack_pages[page_i].deallocate(p, s);
                    } else {
                        p.freeFrame(cur_task.managed_stack_pages[page_i].phys_addr);
                    }
                }
                cur_task.stack_base_phys = 0;
                cur_task.stack_page_count = 0;
            }
        }

        // Find next ready task
        var next_task: ?*Task = null;
        for (&self.tasks) |*t| {
            if (t.state == .ready) {
                next_task = t;
                break;
            }
        }

        if (next_task) |next| {
            next.state = .running;
            self.current_task_id = next.id;
            self.switch_count += 1;
            loadContext(&next.context);
        } else {
            // No ready tasks left: return to primary task if not terminated or hang
            if (self.tasks[0].state != .terminated) {
                self.tasks[0].state = .running;
                self.current_task_id = self.tasks[0].id;
                loadContext(&self.tasks[0].context);
            }
            while (true) {
                if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .freestanding) {
                    asm volatile ("wfe");
                }
            }
        }
    }
};

pub var global_scheduler: Scheduler = .{};

/// Switch context between current and next tasks.
/// On AArch64 bare-metal, performs register save/restore via inline assembly.
/// On hosted/test targets, updates context structures.
pub fn switchContext(current: *TaskContext, next: *const TaskContext) void {
    if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .freestanding) {
        // AArch64 cooperative context switch: save x19-x30, SP, and callee-saved SIMD d8-d15
        asm volatile (
            \\ // Save callee-saved registers into current context
            \\ stp x19, x20, [%[curr], #0]
            \\ stp x21, x22, [%[curr], #16]
            \\ stp x23, x24, [%[curr], #32]
            \\ stp x25, x26, [%[curr], #48]
            \\ stp x27, x28, [%[curr], #64]
            \\ stp x29, x30, [%[curr], #80]
            \\ mov x9, sp
            \\ str x9, [%[curr], #96]
            \\ stp d8, d9, [%[curr], #112]
            \\ stp d10, d11, [%[curr], #128]
            \\ stp d12, d13, [%[curr], #144]
            \\ stp d14, d15, [%[curr], #160]
            \\
            \\ // Restore registers from next context
            \\ ldr x9, [%[nxt], #96]
            \\ mov sp, x9
            \\ ldp x19, x20, [%[nxt], #0]
            \\ ldp x21, x22, [%[nxt], #16]
            \\ ldp x23, x24, [%[nxt], #32]
            \\ ldp x25, x26, [%[nxt], #48]
            \\ ldp x27, x28, [%[nxt], #64]
            \\ ldp x29, x30, [%[nxt], #80]
            \\ ldp d8, d9, [%[nxt], #112]
            \\ ldp d10, d11, [%[nxt], #128]
            \\ ldp d12, d13, [%[nxt], #144]
            \\ ldp d14, d15, [%[nxt], #160]
            \\ ldr x0, [%[nxt], #104] // Pass task arg into x0
            \\ ret
            :
            : [curr] "r" (current),
              [nxt] "r" (next),
            : "x9", "memory"
        );
    } else {
        // Hosted test simulation
        current.x19 = next.x19;
    }
}

/// Load and jump directly into a task context (used on task exit)
pub fn loadContext(next: *const TaskContext) noreturn {
    if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .freestanding) {
        asm volatile (
            \\ ldr x9, [%[nxt], #96]
            \\ mov sp, x9
            \\ ldp x19, x20, [%[nxt], #0]
            \\ ldp x21, x22, [%[nxt], #16]
            \\ ldp x23, x24, [%[nxt], #32]
            \\ ldp x25, x26, [%[nxt], #48]
            \\ ldp x27, x28, [%[nxt], #64]
            \\ ldp x29, x30, [%[nxt], #80]
            \\ ldp d8, d9, [%[nxt], #112]
            \\ ldp d10, d11, [%[nxt], #128]
            \\ ldp d12, d13, [%[nxt], #144]
            \\ ldp d14, d15, [%[nxt], #160]
            \\ ldr x0, [%[nxt], #104] // arg
            \\ br x30
            :
            : [nxt] "r" (next),
            : "x9", "memory"
        );
    }
    while (true) {}
}

/// Trampoline function invoked when a new green thread first starts execution
pub fn taskEntryTrampoline() callconv(.C) void {
    const cur = global_scheduler.getCurrentTask();
    if (cur) |t| {
        if (t.entry) |func| {
            func(t.arg);
        }
    }
    // Clean up and switch when entry function returns
    global_scheduler.exit(&memory.global_pmm, &memory.slab.global_slab);
}

// --------------------------------------------------------------------------
// Unit Tests (Executed on Host via `zig test`)
// --------------------------------------------------------------------------

test "task context structure layout and register offsets" {
    // Ensure TaskContext struct alignment and size are sound
    try std.testing.expect(@sizeOf(TaskContext) >= 176);
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(TaskContext, "x19"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(TaskContext, "x29"));
    try std.testing.expectEqual(@as(usize, 88), @offsetOf(TaskContext, "x30"));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(TaskContext, "sp"));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(TaskContext, "arg"));
    try std.testing.expectEqual(@as(usize, 112), @offsetOf(TaskContext, "d8"));
}

test "scheduler initialization and primary task reservation" {
    var sched: Scheduler = .{};
    sched.init();

    try std.testing.expect(sched.initialized);
    try std.testing.expectEqual(@as(?TaskId, 0), sched.current_task_id);
    try std.testing.expectEqual(@as(usize, 1), sched.task_count);

    const primary = sched.getCurrentTask();
    try std.testing.expect(primary != null);
    try std.testing.expectEqual(TaskState.running, primary.?.state);
    try std.testing.expectEqualStrings("kernel_main", primary.?.getName());
}

test "task spawning state and metadata tracking" {
    var sched: Scheduler = .{};
    sched.init();

    const dummyEntry = struct {
        fn run(arg: u64) void {
            _ = arg;
        }
    }.run;

    const task_id = sched.spawnStatic(dummyEntry, 42, "worker_task") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(TaskId, 1), task_id);
    try std.testing.expectEqual(@as(usize, 2), sched.task_count);

    const task = sched.getTaskById(task_id);
    try std.testing.expect(task != null);
    try std.testing.expectEqual(TaskState.ready, task.?.state);
    try std.testing.expectEqualStrings("worker_task", task.?.getName());
    try std.testing.expectEqual(@as(u64, 42), task.?.arg);
    try std.testing.expectEqual(@as(u64, 42), task.?.context.arg);
    try std.testing.expect(task.?.context.sp != 0);
    // Stack pointer must be 16-byte aligned
    try std.testing.expectEqual(@as(u64, 0), task.?.context.sp & 15);
}

test "cooperative round-robin scheduling transitions" {
    var sched: Scheduler = .{};
    sched.init();

    const dummyEntry = struct {
        fn run(arg: u64) void {
            _ = arg;
        }
    }.run;

    const t1 = sched.spawnStatic(dummyEntry, 10, "task_1") orelse return error.TestUnexpectedResult;
    const t2 = sched.spawnStatic(dummyEntry, 20, "task_2") orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(usize, 3), sched.task_count);

    // Initial state: current is 0 (running), t1 is ready, t2 is ready
    try std.testing.expectEqual(@as(?TaskId, 0), sched.current_task_id);

    // Yield from 0 -> next ready is t1
    sched.yield();
    try std.testing.expectEqual(@as(?TaskId, t1), sched.current_task_id);
    try std.testing.expectEqual(TaskState.running, sched.getTaskById(t1).?.state);
    try std.testing.expectEqual(TaskState.ready, sched.getTaskById(0).?.state);
    try std.testing.expectEqual(@as(u64, 1), sched.switch_count);

    // Yield from t1 -> next ready is t2
    sched.yield();
    try std.testing.expectEqual(@as(?TaskId, t2), sched.current_task_id);
    try std.testing.expectEqual(TaskState.running, sched.getTaskById(t2).?.state);
    try std.testing.expectEqual(TaskState.ready, sched.getTaskById(t1).?.state);
    try std.testing.expectEqual(@as(u64, 2), sched.switch_count);

    // Yield from t2 -> next ready is 0
    sched.yield();
    try std.testing.expectEqual(@as(?TaskId, 0), sched.current_task_id);
    try std.testing.expectEqual(TaskState.running, sched.getTaskById(0).?.state);
    try std.testing.expectEqual(TaskState.ready, sched.getTaskById(t2).?.state);
    try std.testing.expectEqual(@as(u64, 3), sched.switch_count);
}
