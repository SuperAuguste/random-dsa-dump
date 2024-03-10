const std = @import("std");

// invariant: `right != null` iff `left != null`

pub fn Rope(comptime T: type) type {
    return struct {
        const Self = @This();

        const AnyNode = union(enum) {
            node: *Node,
            leaf: *LeafNode,

            fn destroy(node: *AnyNode, allocator: std.mem.Allocator) void {
                switch (node.*) {
                    inline else => |n| n.destroy(allocator),
                }
            }

            /// Gets `length` for `Node`s and `value.len` for `LeafNode`s
            fn getLength(node: AnyNode) u32 {
                return switch (node) {
                    .node => |n| n.length,
                    .leaf => |l| @intCast(l.value.len),
                };
            }

            fn getGraphvizUniqueId(node: AnyNode) usize {
                return switch (node) {
                    inline else => |v| @intFromPtr(v),
                };
            }

            pub fn printGraphviz(node: AnyNode, writer: anytype) !void {
                switch (node) {
                    .node => |n| {
                        try writer.print("{d}[label=\"{d}\"];\n", .{ node.getGraphvizUniqueId(), n.length });
                        if (n.left) |l| {
                            try writer.print("{d} -> {d} [label=\"L\"];\n", .{ node.getGraphvizUniqueId(), l.getGraphvizUniqueId() });
                            try l.printGraphviz(writer);
                        }
                        if (n.right) |r| {
                            try writer.print("{d} -> {d} [label=\"R\"];\n", .{ node.getGraphvizUniqueId(), r.getGraphvizUniqueId() });
                            try r.printGraphviz(writer);
                        }
                    },
                    .leaf => |l| {
                        try writer.print("{d}[label=\"{s} ({d})\"];\n", .{ node.getGraphvizUniqueId(), l.value, l.value.len });
                    },
                }
            }
        };

        pub const Node = struct {
            left: ?AnyNode = null,
            right: ?AnyNode = null,
            length: u32 = 0,

            /// Rope dupes value.
            fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*Node {
                const node = try allocator.create(Node);
                node.* = .{};
                return node;
            }

            fn destroy(node: *Node, allocator: std.mem.Allocator) void {
                if (node.left) |*left| left.destroy(allocator);
                if (node.right) |*right| right.destroy(allocator);

                node.* = undefined;
                allocator.destroy(node);
            }
        };

        pub const LeafNode = struct {
            value: []T,

            /// Rope dupes value.
            fn create(allocator: std.mem.Allocator, value: []const T) error{OutOfMemory}!*LeafNode {
                const node = try allocator.create(LeafNode);
                node.* = .{
                    .value = try allocator.dupe(u8, value),
                };
                return node;
            }

            fn destroy(node: *LeafNode, allocator: std.mem.Allocator) void {
                allocator.free(node.value);
                node.* = undefined;
                allocator.destroy(node);
            }
        };

        root: Node = .{},
        // total_length: u32 = 0,

        pub fn deinit(rope: *Self, allocator: std.mem.Allocator) void {
            if (rope.root.left) |*left| left.destroy(allocator);
            if (rope.root.right) |*right| right.destroy(allocator);
        }

        pub fn prepend(rope: *Self, allocator: std.mem.Allocator, value: []const T) !void {
            if (rope.root.left == null) {
                rope.root.left = .{ .leaf = try LeafNode.create(allocator, value) };
                rope.root.length = @intCast(value.len);
                return;
            }

            const node = try Node.create(allocator);
            node.* = rope.root;
            const leaf = try LeafNode.create(allocator, value);

            rope.root.right = .{ .node = node };
            rope.root.left = .{ .leaf = leaf };
            rope.root.length = @as(u32, @intCast(value.len)) + if (rope.root.right) |r| r.getLength() else 0;
        }

        pub fn append(rope: *Self, allocator: std.mem.Allocator, value: []const T) !void {
            if (rope.root.left == null) {
                rope.root.left = .{ .leaf = try LeafNode.create(allocator, value) };
                rope.root.length = @intCast(value.len);
                return;
            }

            if (rope.root.right == null) {
                rope.root.right = .{ .leaf = try LeafNode.create(allocator, value) };
                rope.root.length += @intCast(value.len);
                return;
            }

            const node = try Node.create(allocator);
            node.* = rope.root;
            const leaf = try LeafNode.create(allocator, value);

            rope.root.left = .{ .node = node };
            rope.root.right = .{ .leaf = leaf };
            rope.root.length += @intCast(value.len);
        }

        pub const Iterator = struct {
            stack: std.ArrayList(AnyNode),

            pub fn next(iterator: *Iterator) error{OutOfMemory}!?*LeafNode {
                const result = iterator.stack.popOrNull() orelse return null;

                while (iterator.stack.popOrNull()) |parent| {
                    if (parent.node.right) |right_node| {
                        var node = right_node;
                        while (node == .node and node.node.left != null) {
                            try iterator.stack.append(node);
                            node = node.node.left.?;
                        }
                        try iterator.stack.append(node);
                        std.debug.assert(node == .leaf);
                        break;
                    }
                }

                return result.leaf;
            }

            pub fn deinit(iterator: *Iterator) void {
                iterator.stack.deinit();
                iterator.* = undefined;
            }
        };

        /// Caller must deinit `Iterator` when they are done.
        pub fn iterate(rope: *Self, allocator: std.mem.Allocator) error{OutOfMemory}!Iterator {
            var iterator = Iterator{ .stack = std.ArrayList(AnyNode).init(allocator) };

            if (rope.root.left == null) return iterator;

            var node = AnyNode{ .node = &rope.root };
            while (node == .node and node.node.left != null) {
                try iterator.stack.append(node);
                node = node.node.left.?;
            }
            try iterator.stack.append(node);
            std.debug.assert(node == .leaf);

            return iterator;
        }

        /// Iterate through rope and collect into a list
        pub fn collect(rope: *Self, allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(T)) error{OutOfMemory}!void {
            var iterator = try rope.iterate(allocator);
            defer iterator.deinit();

            while (try iterator.next()) |leaf| {
                try list.appendSlice(allocator, leaf.value);
            }
        }

        pub fn at(rope: *Self, index: u32) T {
            var node = &rope.root;
            var adjusted_index = index;

            while (true) {
                const next_node, adjusted_index = if (adjusted_index < node.left.?.getLength())
                    .{ node.left, adjusted_index }
                else
                    .{ node.right, adjusted_index - node.left.?.getLength() };

                switch (next_node.?) {
                    .node => |n| node = n,
                    .leaf => |l| return l.value[adjusted_index],
                }
            }
        }

        /// Combine two `Rope`s.
        pub fn concat(left: Self, right: Self, allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            const new_left = try allocator.create(Node);
            new_left.* = left.root;
            const new_right = try allocator.create(Node);
            new_right.* = right.root;

            return .{
                .node = .{
                    .left = new_left,
                    .right = new_right,
                    .length = left.root.length + right.root.length,
                },
            };
        }

        pub fn printGraphviz(rope: *Self, writer: anytype) !void {
            try writer.writeAll("digraph preview {");
            try (AnyNode{ .node = &rope.root }).printGraphviz(writer);
            try writer.writeAll("}");
        }
    };
}

test {
    const allocator = std.testing.allocator;
    // const allocator = std.heap.page_allocator;

    const StringRope = Rope(u8);

    var rope = StringRope{};
    defer rope.deinit(allocator);

    try rope.prepend(allocator, ") void ");
    try rope.prepend(allocator, "abc(");
    try rope.append(allocator, "{");
    try rope.append(allocator, "hello();");
    try rope.prepend(allocator, "fn ");
    try rope.prepend(allocator, "pub ");
    try rope.append(allocator, "}");

    var out = try std.fs.cwd().createFile("abc.dot", .{});
    defer out.close();

    try rope.printGraphviz(out.writer());

    var collected = std.ArrayListUnmanaged(u8){};
    defer collected.deinit(allocator);

    try rope.collect(allocator, &collected);

    for (collected.items, 0..) |c, i| {
        try std.testing.expectFmt(&.{c}, "{c}", .{rope.at(@intCast(i))});
    }
}
