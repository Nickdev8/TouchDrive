import os
import sys

import bpy
import bmesh


def _clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)


def _create_cliff_blockout():
    mesh = bpy.data.meshes.new("Cliff_BlockoutMesh")
    obj = bpy.data.objects.new("Cliff_Blockout", mesh)
    bpy.context.scene.collection.objects.link(obj)

    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=24, y_segments=16, size=1.0)

    for vert in bm.verts:
        # Scale up to a large play area.
        vert.co.x *= 25.0
        vert.co.y *= 18.0

        # Carve a shelf road on the right half, drop a cliff on the left.
        if vert.co.x < -6.0:
            vert.co.z = -6.0
        elif vert.co.x < -2.0:
            t = (vert.co.x + 6.0) / 4.0
            vert.co.z = -6.0 + t * 6.0
        else:
            vert.co.z = 0.0

        # Gentle uphill along Y for a ramp feel.
        vert.co.z += (vert.co.y / 18.0) * 2.5

    bm.to_mesh(mesh)
    bm.free()

    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.shade_flat()
    return obj


def _create_road_collider():
    mesh = bpy.data.meshes.new("Road_ColliderMesh")
    obj = bpy.data.objects.new("Road_Collider", mesh)
    bpy.context.scene.collection.objects.link(obj)

    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=4, y_segments=16, size=1.0)
    for vert in bm.verts:
        vert.co.x *= 12.0
        vert.co.y *= 18.0
        vert.co.z = 0.05 + (vert.co.y / 18.0) * 2.5
    bm.to_mesh(mesh)
    bm.free()

    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.shade_flat()
    return obj


def _create_start_marker():
    empty = bpy.data.objects.new("Start_Marker", None)
    empty.empty_display_type = "ARROWS"
    empty.location = (6.0, -10.0, 1.0)
    bpy.context.scene.collection.objects.link(empty)
    return empty


def _target_path():
    args = sys.argv
    if "--" in args:
        idx = args.index("--")
        tail = args[idx + 1 :]
        if tail:
            return tail[0]
    default_dir = os.path.join(os.getcwd(), "assets", "source", "terrain")
    os.makedirs(default_dir, exist_ok=True)
    return os.path.join(default_dir, "terrain_blockout.blend")


def main():
    _clear_scene()
    _create_cliff_blockout()
    _create_road_collider()
    _create_start_marker()

    path = _target_path()
    bpy.ops.wm.save_as_mainfile(filepath=path)
    print("Saved:", path)


if __name__ == "__main__":
    main()
