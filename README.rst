This is a port to Open Dylan of the ``melange`` tool from Gwydion Dylan.

``melange`` is used to generate C-FFI bindings to libraries with a C API
by parsing C header files.

Build
-----

    export OPEN_DYLAN_USER_REGISTRIES=`pwd`/registry
    dylan-compiler -build parsergen
    ~/Open-Dylan/bin/parsergen melange/c-parse.input melange/c-parse.dylan
    ~/Open-Dylan/bin/parsergen melange/int-parse.input melange/int-parse.dylan
    dylan-compiler -build melange

Usage
-----

The documentation for this tool will be ported in the future.
