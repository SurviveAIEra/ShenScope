# Julia runtime image integrity and build experiment

Checkpoint 030 adds Core-owned source inventories and runtime-image receipts.
PackageCompiler is a separately pinned research/build dependency; it is absent
from the application's Project.toml and normal startup requirements. The build
environment develops the existing Core checkout and existing PackageCompiler
checkout into one shared depot. It never copies either application directory.

The source inventory covers Project.toml, Manifest.toml, optional package
preferences, and Julia files beneath src and ext. Sorted relative paths, byte
counts and SHA-256 hashes form a canonical fingerprint with package UUID/version.
The inventory rejects descendant symlinks and bounds directory entries, files
and total source bytes. It is a repeated consistency check, not an atomic
multi-file snapshot. Scripts, docs, tests, editor assets and Git history are not
compiled Core source and are excluded from that fingerprint.

An image receipt records the inventory, exact Julia version/platform, generic CPU
target, image filename/size/hash and PackageCompiler environment/identity.
Verification re-reads the receipt, current source and image before returning a
detached plan. Unknown schema fields, duplicate JSON keys, excessive nesting,
traversal names, altered locks/source/preferences, wrong platform, symlinks and
changed image bytes refuse verification. ELF class/machine inspection confirms
declared binary architecture; it does not prove compiled instructions or origin.
There is no signature or publisher attestation.

Read permission governs inspection and hashing. Persistence separately governs
atomic receipt publication. Dynamic-code permission separately governs creating
a checked launch argument vector. Planning starts no process; executing the
vector still requires the caller's process authorization. Live Deny, cancellation
and shared budget checks apply during bounded reads and hashing. A returned plan
does not prevent later file replacement between verification and execution.

The optional build script refuses an existing output image and compares every
Core dependency's UUID/version/tree identity with the dedicated compiler
environment. It captures the source before compilation and checks it again
before publishing the receipt. Its disposable workload covers server metadata,
a MockProvider write/read-capable agent path and JuliaSyntax dispatch queries;
it never contacts a model, executes a command or reads user configuration.
No workload server or session is kept in a module global.

```sh
# Uses the already cloned, pinned compiler checkout and checks space.
python scripts/setup_sysimage.py
JULIA_DEPOT_PATH=/workspace/julia-depot \
  julia --startup-file=no --project=.local/packagecompiler-environment \
  scripts/build_sysimage.jl .local/sysimage-030

# These inspect or plan; they do not install or execute the image.
bin/shenscope \
  runtime-image verify .local/sysimage-030/shenscope-core.receipt.json
bin/shenscope \
  runtime-image plan .local/sysimage-030/shenscope-core.receipt.json
```

PackageCompiler sysimages freeze loaded packages and may take precedence over
the active dependency environment. These checks make that constraint explicit.
Current image support is an incremental generic Linux ELF experiment using an
existing Julia installation, not a standalone application or desktop installer.
Compiled source locations can retain absolute helper paths; relocation and
clean-machine restoration remain unverified. Both editor launchers still use
normal Julia startup. The `runtime/status` loaded-image report is observational:
an environment-supplied fingerprint is identified as a loader report, never as
verified provenance. Actual artifact measurements and failure records belong
to the checkpoint validation report.

The verified checkpoint retains its receipt and raw observations under
`docs/validation/sysimage-030`. The 297 MiB experimental binary and compiler-only
cache/trace artifacts were removed after validation, reclaiming 423,664,125 bytes.
The examples above require rebuilding the image first. One current ordinary
Core package cache pair remains; no launcher configuration points to this image.
