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
    zombie_task: ?TaskId = null,
    pmm: ?*memory.PhysicalMemoryManager = null,
    slab_alloc: ?*memory.slab.SlabAllocator = null,

    // Static stacks for mock/host testing if needed
    static_stacks: [MAX_TASKS][DEFAULT_STACK_SIZE]u8 align(16) = undefined,

    pub fn init(self: *Scheduler) void {
        self.current_task_id = null;
        self.next_task_id = 1;
        self.task_count = 0;
        self.switch_count = 0;
        self.zombie_task = null;
        self.pmm = null;
        self.slab_alloc = null;

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
        self.pmm = pmm;

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

    /// Find the next ready task in round-robin order starting after the specified task ID.
    pub fn findNextReadyTask(self: *Scheduler, from_task_id: TaskId) ?*Task {
        var start_idx: usize = 0;
        for (&self.tasks, 0..) |*t, i| {
            if (t.id == from_task_id) {
                start_idx = (i + 1) % MAX_TASKS;
                break;
            }
        }

        var i: usize = 0;
        while (i < MAX_TASKS) : (i += 1) {
            const check_idx = (start_idx + i) % MAX_TASKS;
            const candidate = &self.tasks[check_idx];
            if (candidate.state == .ready) {
                return candidate;
            }
        }
        return null;
    }

    /// Yield execution cooperatively to the next ready task.
    /// Strictly maintains Law of the Single Flat Space: switches registers only,
    /// no TTBR0/1 or TLB flushes.
    pub fn yield(self: *Scheduler) void {
        const cur_id = self.current_task_id orelse return;
        const cur_task = self.getTaskById(cur_id) orelse return;

        // Find next ready task (Round-Robin)
        const next = self.findNextReadyTask(cur_id) orelse return;

        // Perform context switch
        if (cur_task.state == .running) {
            cur_task.state = .ready;
        }
        cur_task.yield_count += 1;

        next.state = .running;
        self.current_task_id = next.id;
        self.switch_count += 1;

        if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .freestanding) {
            const switch_fn: *const fn (*TaskContext, *const TaskContext) callconv(.C) void = @ptrCast(&switchContext);
            switch_fn(&cur_task.context, &next.context);
        } else {
            // Hosted test simulation
            cur_task.context.x19 = next.context.x19;
        }

        // Resumed execution on next task's stack: free any deferred zombie stack
        self.reclaimZombie(self.pmm orelse (if (builtin.os.tag == .freestanding) &memory.global_pmm else null), self.slab_alloc orelse (if (builtin.os.tag == .freestanding) &memory.slab.global_slab else null));
    }

    /// Free deferred stack frames of a terminated task.
    /// Executed on the stack of the next scheduled task or idle loop to avoid use-after-free.
    pub fn reclaimZombie(self: *Scheduler, pmm: ?*memory.PhysicalMemoryManager, slab_alloc: ?*memory.slab.SlabAllocator) void {
        const zid = self.zombie_task orelse return;
        const ztask = self.getTaskById(zid) orelse {
            self.zombie_task = null;
            return;
        };

        const eff_pmm = pmm orelse self.pmm;
        const eff_slab = slab_alloc orelse self.slab_alloc;

        if (eff_pmm) |p| {
            if (ztask.stack_base_phys != 0) {
                var page_i: usize = 0;
                while (page_i < ztask.stack_page_count) : (page_i += 1) {
                    if (eff_slab) |s| {
                        ztask.managed_stack_pages[page_i].deallocate(p, s);
                    } else {
                        p.freeFrame(ztask.managed_stack_pages[page_i].phys_addr);
                    }
                }
                ztask.stack_base_phys = 0;
                ztask.stack_page_count = 0;
            }
        }
        ztask.state = .unused;
        self.zombie_task = null;
    }

    /// Terminate current task and switch to the next ready task.
    /// Defers stack reclamation to prevent use-after-free while executing on the current task's stack.
    pub fn exit(self: *Scheduler, pmm: ?*memory.PhysicalMemoryManager, slab_alloc: ?*memory.slab.SlabAllocator) noreturn {
        const cur_id = self.current_task_id orelse {
            while (true) {}
        };
        const cur_task = self.getTaskById(cur_id) orelse {
            while (true) {}
        };

        cur_task.state = .terminated;
        if (self.task_count > 0) self.task_count -= 1;

        // Defer stack reclamation to prevent use-after-free: store terminating task ID in zombie_task
        self.zombie_task = cur_id;
        if (pmm) |p| self.pmm = p;
        if (slab_alloc) |s| self.slab_alloc = s;

        // Find next ready task (Round-Robin)
        const next_task = self.findNextReadyTask(cur_id);

        if (next_task) |next| {
            next.state = .running;
            self.current_task_id = next.id;
            self.switch_count += 1;
            loadContext(&next.context);
        } else {
            // No ready tasks left: return to primary task if not terminated or hang in idle loop
            if (self.tasks[0].state != .terminated) {
                self.tasks[0].state = .running;
                self.current_task_id = self.tasks[0].id;
                loadContext(&self.tasks[0].context);
            }

            // Idle loop: switch away from terminating task stack before reclaiming zombie stack
            const idle_sp = @as(usize, @intFromPtr(&self.static_stacks[0][0])) + DEFAULT_STACK_SIZE;
            if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .freestanding) {
                asm volatile (
                    \\ mov sp, %[sp]
                    :
                    : [sp] "r" (idle_sp & ~@as(usize, 15)),
                    : "memory"
                );
            }
            self.reclaimZombie(self.pmm, self.slab_alloc);
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
/// Uses callconv(.Naked) to prevent compiler prologue/epilogue from corrupting stack frames.
/// On hosted/test targets, updates context structures.
pub fn switchContext(current: *TaskContext, next: *const TaskContext) callconv(.Naked) void {
    _ = current;
    _ = next;
    if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .freestanding) {
        // AArch64 cooperative context switch: save x19-x30, SP, and callee-saved SIMD d8-d15
        // x0 = current context, x1 = next context via standard calling convention
        asm volatile (
            \\ // Save callee-saved registers into current context
            \\ stp x19, x20, [x0, #0]
            \\ stp x21, x22, [x0, #16]
            \\ stp x23, x24, [x0, #32]
            \\ stp x25, x26, [x0, #48]
            \\ stp x27, x28, [x0, #64]
            \\ stp x29, x30, [x0, #80]
            \\ mov x9, sp
            \\ str x9, [x0, #96]
            \\ stp d8, d9, [x0, #112]
            \\ stp d10, d11, [x0, #128]
            \\ stp d12, d13, [x0, #144]
            \\ stp d14, d15, [x0, #160]
            \\
            \\ // Restore registers from next context
            \\ ldr x9, [x1, #96]
            \\ mov sp, x9
            \\ ldp x19, x20, [x1, #0]
            \\ ldp x21, x22, [x1, #16]
            \\ ldp x23, x24, [x1, #32]
            \\ ldp x25, x26, [x1, #48]
            \\ ldp x27, x28, [x1, #64]
            \\ ldp x29, x30, [x1, #80]
            \\ ldp d8, d9, [x1, #112]
            \\ ldp d10, d11, [x1, #128]
            \\ ldp d12, d13, [x1, #144]
            \\ ldp d14, d15, [x1, #160]
            \\ ldr x0, [x1, #104] // Pass task arg into x0
            \\ ret
        );
    } else {
        asm volatile ("ret");
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
    // Reclaim deferred zombie stack now that we are executing on the newly scheduled task's stack
    global_scheduler.reclaimZombie(global_scheduler.pmm orelse (if (builtin.os.tag == .freestanding) &memory.global_pmm else null), global_scheduler.slab_alloc orelse (if (builtin.os.tag == .freestanding) &memory.slab.global_slab else null));

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

test "round-robin task selection on exit resumes next ready task in circular order" {
    var sched: Scheduler = .{};
    sched.init();

    const dummyEntry = struct {
        fn run(arg: u64) void {
            _ = arg;
        }
    }.run;

    const t1 = sched.spawnStatic(dummyEntry, 10, "worker_1") orelse return error.TestUnexpectedResult;
    const t2 = sched.spawnStatic(dummyEntry, 20, "worker_2") orelse return error.TestUnexpectedResult;

    // Simulate kernel_main (slot 0) yielding to t1
    sched.getTaskById(0).?.state = .ready;
    sched.getTaskById(t1).?.state = .running;
    sched.current_task_id = t1;

    // When t1 exits, round-robin scan starting after slot 1 picks t2 (slot 2), not slot 0
    sched.getTaskById(t1).?.state = .terminated;
    const next_after_t1 = sched.findNextReadyTask(t1);
    try std.testing.expect(next_after_t1 != null);
    try std.testing.expectEqual(t2, next_after_t1.?.id);

    // When t2 runs and exits, round-robin scan starting after slot 2 wraps around to slot 0 (kernel_main)
    sched.getTaskById(t2).?.state = .terminated;
    const next_after_t2 = sched.findNextReadyTask(t2);
    try std.testing.expect(next_after_t2 != null);
    try std.testing.expectEqual(@as(TaskId, 0), next_after_t2.?.id);
}

test "round-robin exit wraps around task table boundary and handles empty ready set" {
    var sched: Scheduler = .{};
    sched.init();

    // Mark task 0 (kernel_main) as terminated
    sched.getTaskById(0).?.state = .terminated;

    // With no tasks ready, findNextReadyTask returns null
    try std.testing.expectEqual(@as(?*Task, null), sched.findNextReadyTask(0));

    // Place a ready task at the very end of tasks array (slot MAX_TASKS - 1)
    const last_slot = MAX_TASKS - 1;
    sched.tasks[last_slot].id = 999;
    sched.tasks[last_slot].state = .ready;

    // Place a ready task at slot 5
    sched.tasks[5].id = 555;
    sched.tasks[5].state = .ready;

    // When last_slot exits, search wraps around index 0 and finds slot 5
    sched.tasks[last_slot].state = .terminated;
    const next = sched.findNextReadyTask(999);
    try std.testing.expect(next != null);
    try std.testing.expectEqual(@as(TaskId, 555), next.?.id);

    // When slot 5 terminates, search from slot 5 finds nothing and returns null
    sched.tasks[5].state = .terminated;
    try std.testing.expectEqual(@as(?*Task, null), sched.findNextReadyTask(555));
}

test "deferred stack reclamation via zombie_task on exit" {
    var sched: Scheduler = .{};
    sched.init();

    const dummyEntry = struct {
        fn run(arg: u64) void {
            _ = arg;
        }
    }.run;

    const t1 = sched.spawnStatic(dummyEntry, 10, "task_1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), sched.task_count);

    // Simulate task 1 running and exiting
    sched.current_task_id = t1;
    sched.getTaskById(t1).?.state = .running;
    sched.zombie_task = t1;
    sched.getTaskById(t1).?.state = .terminated;
    sched.task_count -= 1;

    try std.testing.expectEqual(@as(?TaskId, t1), sched.zombie_task);

    // Reclaim zombie on next task execution
    sched.reclaimZombie(null, null);
    try std.testing.expectEqual(@as(?TaskId, null), sched.zombie_task);
    try std.testing.expectEqual(TaskState.unused, sched.tasks[1].state);
    try std.testing.expectEqual(@as(?*Task, null), sched.getTaskById(t1));
}

test "task slot reuse after zombie reclamation prevents MAX_TASKS exhaustion" {
    var sched: Scheduler = .{};
    sched.init();

    const dummyEntry = struct {
        fn run(arg: u64) void {
            _ = arg;
        }
    }.run;

    // Sequentially spawn, terminate, and reclaim tasks well past MAX_TASKS (e.g., 100 cycles)
    var cycle: usize = 0;
    while (cycle < 100) : (cycle += 1) {
        const tid = sched.spawnStatic(dummyEntry, @as(u64, cycle), "worker_cycle") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 2), sched.task_count);

        // Terminate and defer reclamation
        sched.current_task_id = tid;
        sched.getTaskById(tid).?.state = .terminated;
        sched.zombie_task = tid;
        sched.task_count -= 1;

        // Reclaim zombie, freeing the slot to .unused
        sched.reclaimZombie(null, null);
        try std.testing.expectEqual(@as(?TaskId, null), sched.zombie_task);
        try std.testing.expectEqual(TaskState.unused, sched.tasks[1].state);
    }
}

test "reclaimZombie deallocates physical stack frames after context switch" {
    const limine = @import("limine.zig");
    const mock_ram_size: usize = 2 * 1024 * 1024;
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: memory.PhysicalMemoryManager = .{};
    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entry_ptrs = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entry_ptrs,
    };
    pmm.init(base_addr, &mock_mmap);

    var sched: Scheduler = .{};
    sched.init();

    const dummyEntry = struct {
        fn run(arg: u64) void {
            _ = arg;
        }
    }.run;

    const initial_free = pmm.free_frames;
    const t1 = sched.spawn(&pmm, dummyEntry, 10, "worker") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(initial_free - STACK_PAGE_COUNT, pmm.free_frames);

    // Simulate task termination: mark terminated, set zombie_task, stack NOT yet freed
    sched.zombie_task = t1;
    sched.getTaskById(t1).?.state = .terminated;

    // Stack is still allocated while zombie_task is set
    try std.testing.expectEqual(initial_free - STACK_PAGE_COUNT, pmm.free_frames);

    // Switch contexts to another task and reclaim zombie stack
    sched.reclaimZombie(&pmm, null);
    try std.testing.expectEqual(@as(?TaskId, null), sched.zombie_task);
    // Stack frames are now freed back to PMM
    try std.testing.expectEqual(initial_free, pmm.free_frames);
}
