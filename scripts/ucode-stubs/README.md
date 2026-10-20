# Native module stubs

`import { readfile } from 'fs'` resolves at runtime to a shared object that
only exists on an OpenWrt device. These stubs stand in for those modules so
`scripts/check-ucode.sh` can compile the console on a developer machine.

They are not mocks and nothing executes them — the checker compiles, it does
not run. Their value beyond satisfying the resolver is that **an import of a
name a stub does not declare fails the check**. So when you reach for a
function, add it here at the same time, having confirmed it exists in the real
module. That turns "I assumed ucode's fs had this" into a compile error rather
than a 500 on a gateway in a car park.

Sources of truth:
  fs, uci, ubus, digest, socket — https://github.com/jow-/ucode/tree/master/lib
