#!/bin/bash
# Stub memory reader (MEMGATE_READER_CMD) reporting plenty of free memory.
cat <<'EOF'
Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                         2000000.
Pages active:                       1000000.
Pages inactive:                     2000000.
Pages speculative:                   500000.
Pages throttled:                          0.
Pages wired down:                    500000.
Pages purgeable:                     500000.
EOF
