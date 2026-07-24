#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="/path/to/project/CellarCXL-ReadOnly"
BUILD_DIR="$REPO_ROOT/build"

export PATH="/path/to/project/local/bin:$PATH"
export LD_LIBRARY_PATH="/path/to/project/local/lib64:${LD_LIBRARY_PATH:-}"
export CC="/path/to/project/local/bin/gcc"
export CXX="/path/to/project/local/bin/g++"

cd "$BUILD_DIR"
cmake .. -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
make -j$(nproc) exp6_convergence_test

echo "[DONE] exp6_convergence_test built at: $BUILD_DIR/frontend/exp6_convergence_test"
