# PythonKit

This package is based on PythonKit [v0.5.1](https://github.com/pvieito/PythonKit/tree/v0.5.1)
(`6fee7617`). The original license is in [LICENSE.txt](LICENSE.txt).

The local changes use public CPython APIs for boolean conversion, avoid
initializing an already initialized embedded interpreter, and use the
two-argument UTF-8 string constructor matching the Swift binding.
