const std = @import("std");

pub fn UnrolledSinglyLinkedList(comptime T: type, comptime max_items_per_node: usize) type {
    return struct {
        pub const Node = struct {
            pub const LengthInt = std.math.IntFittingRange(0, max_items_per_node);

            items: [max_items_per_node]T = undefined,
            len: LengthInt = 0,
            next: ?*Node = null,

            pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*Node {
                const node = try allocator.create(Node);
                node.* = .{};
                return node;
            }

            pub fn destroy(node: *Node, allocator: std.mem.Allocator) void {
                node.* = undefined;
                allocator.destroy(node);
            }

            /// Destroy `node` and all nodes following it.
            pub fn destroyAll(start_node: *Node, allocator: std.mem.Allocator) void {
                var node = start_node;
                while (node.next) |next| {
                    node.destroy(allocator);
                    node = next;
                }
                node.destroy(allocator);
            }

            pub fn slice(node: *Node) []T {
                return node.items[0..node.len];
            }

            pub fn constSlice(node: Node) []const T {
                return node.items[0..node.len];
            }

            pub fn lastNode(node: *Node) *Node {
                var last_node = node;
                while (last_node.next) |next| {
                    last_node = next;
                }
                return last_node;
            }

            /// Get the first node with available space, if it exists.
            pub fn firstOpenNode(node: *Node) ?*Node {
                var open_node = node;
                while (open_node.next) |next| : (open_node = next) {
                    if (open_node.len < max_items_per_node) {
                        return open_node;
                    }
                }

                return if (open_node.len < max_items_per_node)
                    open_node
                else
                    null;
            }

            /// Counts number of nodes from this `start_node`, including `start_node`.
            pub fn countNodes(start_node: *Node) usize {
                var count: usize = 1;
                var node = start_node;
                while (node.next) |next| : (node = next) {
                    count += 1;
                }
                return count;
            }

            /// Counts number of items from this `start_node`, including `start_node`.
            pub fn countItems(start_node: *Node) usize {
                var count: usize = 0;
                var node = start_node;
                while (node.next) |next| : (node = next) {
                    count += node.len;
                }
                count += node.len;
                return count;
            }

            pub const ItemIterator = struct {
                node: *Node,
                index: LengthInt = 0,

                pub fn next(iterator: *ItemIterator) ?T {
                    if (iterator.index >= iterator.node.len) {
                        iterator.node = iterator.node.next orelse return null;
                        iterator.index = 0;
                    }

                    const item = iterator.node.items[iterator.index];
                    iterator.index += 1;
                    return item;
                }
            };

            /// Iterates items from `start_node`.
            pub fn iterateItems(start_node: *Node) ItemIterator {
                return .{ .node = start_node };
            }

            /// Appends with the following logic:
            ///   - Get the `node.lastNode()`.
            ///   - Check if we can `last_node.appendInNode(...)`.
            ///   - If we cannot, we create a new `next` Node.
            ///
            /// We return the Node that was operated on, which is always
            /// the now-`node.lastNode()`.
            ///
            /// For efficient appending:
            ///   - Use `appendSlice` if you already have your `items` collected.
            ///   - Repeatedly invoke `append` on the returned `node` to needless
            ///     pointer following.
            pub fn append(node: *Node, allocator: std.mem.Allocator, item: T) error{OutOfMemory}!*Node {
                const last_node = node.lastNode();

                const node_to_append_to = if (last_node.len < max_items_per_node) last_node else blk: {
                    const new_node = try Node.create(allocator);
                    last_node.next = new_node;
                    break :blk new_node;
                };

                node_to_append_to.appendInNodeAssumeLength(item);
                return node_to_append_to;
            }

            /// Same as `append`, but for multiple `items`.
            pub fn appendSlice(node: *Node, allocator: std.mem.Allocator, items: []const T) error{OutOfMemory}!*Node {
                var last_node = node;
                for (items) |item| {
                    // TODO: appendSliceInNode
                    last_node = try last_node.append(allocator, item);
                }
                return last_node;
            }

            /// Tries attempting within `node.items` only. Will
            /// return an `error.OutOfMemory` if `node.len >= max_items_per_node`.
            pub fn appendInNode(node: *Node, item: T) error{OutOfMemory}!void {
                if (node.len >= max_items_per_node) return error.OutOfMemory;
                node.items[node.len] = item;
                node.len += 1;
            }

            /// Appends directly to `node.items`.
            pub fn appendInNodeAssumeLength(node: *Node, item: T) void {
                std.debug.assert(node.len < max_items_per_node);
                node.items[node.len] = item;
                node.len += 1;
            }

            /// Removes an element at `index` by swapping the last item in. O(1).
            pub fn swapRemove(node: *Node, index: LengthInt) T {
                std.debug.assert(node.len > index);
                const removed_item = node.items[index];
                node.items[index] = node.items[node.len - 1];
                node.len -= 1;
                return removed_item;
            }

            /// Removes an element at `index` by moving the remaining items. O(N).
            pub fn orderedRemove(node: *Node, index: LengthInt) T {
                _ = node; // autofix
                _ = index; // autofix
                @compileError("TODO");
            }

            /// Packs this `node` and all next nodes as tightly as possible,
            /// `destroy`ing any now-empty `Node`s.
            pub fn compact(node: *Node, allocator: std.mem.Allocator) error{OutOfMemory}!void {
                // If no open node exists, no compacting can be done.
                var open_node = node.firstOpenNode() orelse return;
                const last_node = node.lastNode();

                // If the open node and last node are the same, we're done
                while (open_node != last_node) {
                    const available_space = max_items_per_node - open_node.len;
                    const after_open_node = open_node.next.?;
                    const actual_move_len = @min(after_open_node.len, available_space);

                    @memcpy(open_node.items[open_node.len .. open_node.len + actual_move_len], after_open_node.items[0..actual_move_len]);
                    std.mem.copyBackwards(T, &after_open_node.items, after_open_node.items[actual_move_len..]);

                    open_node.len += @intCast(actual_move_len);
                    after_open_node.len -= @intCast(actual_move_len);

                    // TODO: i implemented the code below when i was absolutely
                    // exhausted and it looks really sus and needlessly complicated

                    var prev = open_node;
                    var next_non_empty_node = after_open_node;

                    while (next_non_empty_node.len == 0) {
                        const dead_node = next_non_empty_node;
                        next_non_empty_node = dead_node.next orelse {
                            prev.next = null;
                            dead_node.destroy(allocator);
                            return;
                        };
                        prev.next = next_non_empty_node;
                        dead_node.destroy(allocator);
                        prev = next_non_empty_node;
                    }
                    open_node = next_non_empty_node;
                }
            }
        };

        // TODO: Make this struct useful
    };
}

test {
    const allocator = std.testing.allocator;

    const USLT = UnrolledSinglyLinkedList(u8, 4);

    var node = try USLT.Node.create(allocator);
    defer node.destroyAll(allocator);

    _ = try node.append(allocator, 1);
    _ = try node.append(allocator, 2);
    _ = try node.append(allocator, 3);
    _ = try node.append(allocator, 4);
    _ = try node.appendSlice(allocator, &.{ 5, 6, 7, 8, 9 });
    _ = try node.append(allocator, 10);
    const node_b = try node.append(allocator, 11);
    node_b.next = try USLT.Node.create(allocator);
    const node_c = try node_b.append(allocator, 12);
    node_c.next = try USLT.Node.create(allocator);
    _ = try node_c.append(allocator, 13);
    const node_d = try node.append(allocator, 14);

    try std.testing.expectEqual(5, node.countNodes());
    try std.testing.expectEqual(14, node.countItems());
    try std.testing.expectEqual(node_d, node.lastNode());
    try std.testing.expectEqual(node_b, node.firstOpenNode());

    var checklist = std.ArrayListUnmanaged(u8){};
    defer checklist.deinit(allocator);

    var it = node.iterateItems();
    while (it.next()) |d| {
        try checklist.append(allocator, d);
    }

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 }, checklist.items);
    checklist.items.len = 0;

    try node.compact(allocator);

    it = node.iterateItems();
    while (it.next()) |d| {
        try checklist.append(allocator, d);
    }

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 }, checklist.items);

    try std.testing.expectEqual(4, node.countNodes());
    try std.testing.expectEqual(14, node.countItems());
}
