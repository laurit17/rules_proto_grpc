load("//python:python_proto_compile.bzl", "python_proto_compile")

load(
    "@com_bluecore_rules_pyz//rules_python_zip:rules_python_zip.bzl",
    "pyz_binary",
    "pyz_library",
    "pyz_test",
)

def pyz_proto_library(**kwargs):
    # Compile protos
    name_pb = kwargs.get("name") + "_pb"
    python_proto_compile(
        name = name_pb,
        **{k: v for (k, v) in kwargs.items() if k in ("deps", "verbose")} # Forward args
    )

    # Create python library
    pyz_library(
        name = kwargs.get("name"),
        srcs = [name_pb],
        pythonroot = name_pb,
        # deps = PROTO_DEPS,
        visibility = kwargs.get("visibility"),
    )

PROTO_DEPS = [
    "@com_google_protobuf//:protobuf_python",
]
