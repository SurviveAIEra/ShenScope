# Third-party notices

Reference repositories are research-only and excluded from ShenScope code and
release artifacts. No agent implementation is copied or translated into Core.
See the reference lockfile for exact revisions and component licenses.

Serena application is GPL-3.0-or-later at the inspected revision; only its
behavior is studied. SolidLSP is separately MIT. Do not incorporate GPL code
into Apache-2.0 Core. Code-OSS is MIT and will retain upstream notices when
distributed. Do not distribute Microsoft's proprietary product branding.

Julia and direct/transitive runtime dependencies retain their upstream license
obligations. A distribution must include the corresponding license inventory.

JuliaSyntax.jl 0.4.10 (JuliaLang/JuliaSyntax.jl, MIT; copyright 2021 Julia
Computing and contributors) is a pinned source parser dependency. It is installed
through Julia's package manager and is not counted as authored Core code. Its
license accompanies the upstream dependency. Core extraction and graph/query
logic are independently implemented; distribution license inventories remain
required when dependencies are bundled.
# Skills parsing dependency

YAML.jl 0.4.17 (JuliaData/YAML.jl, MIT) is a general YAML parser dependency,
not an embedded agent implementation. Its transitive StringEncodings.jl and
Libiconv_jll dependencies are pinned in Manifest.toml. Native libiconv packaging
and its LGPL notices must accompany any future distribution that bundles it;
the current VSIX includes authored Core source and the manifest, not those binaries.
