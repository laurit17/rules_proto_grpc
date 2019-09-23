load("//python:python_proto_compile.bzl", "python_proto_compile")

load(
    "@com_bluecore_rules_pyz//rules_python_zip:rules_python_zip.bzl",
    "pyz_library",
)

def python_proto_library(**kwargs):
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
        deps = PROTO_DEPS,
        pythonroot = name_pb,
        visibility = kwargs.get("visibility"),
    )

PROTO_DEPS = [
    # "@com_google_protobuf//:protobuf_python",
    "//third_party/pypi:protobuf",
]
