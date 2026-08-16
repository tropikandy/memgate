#!/bin/bash
# Stub memory reader (MEMGATE_READER_CMD) reporting memory below any
# reasonable floor. Mimics vm_stat's output shape closely enough for
# memgate's parser.
cat <<'EOF'
Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                              10.
Pages active:                       1000000.
Pages inactive:                          10.
Pages speculative:                       10.
Pages throttled:                          0.
Pages wired down:                    500000.
Pages purgeable:                         10.
EOF
