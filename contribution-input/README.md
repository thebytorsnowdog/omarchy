# Offline source packet for Omarchy contribution validation

The coordinator fetched public upstream and PR refs on 2026-10-16. `manifest.json` records exact commit/tree hashes. Every compressed binary patch transforms the upstream source tree into the named snapshot, and was checked by applying it to a separate Git index and comparing the complete resulting tree hash. Metadata is captured from the public GitHub API. No GitHub credentials are included.

The cloud environment previously rejected GitHub fetches. Use this packet instead of network access; the supplied metadata is a dated observation, not a live status query.

To materialize a snapshot without needing history or network:

1. Make a temporary directory and set `GIT_INDEX_FILE` to a nonexistent path inside it (for these Git commands only).
2. Run `git read-tree HEAD`, then `git rm -r --cached --ignore-unmatch contribution-input` using that temporary index. This removes only the packet from the temporary index, leaving the upstream source tree.
3. Decompress the chosen patch and pipe it into `git apply --cached --binary --whitespace=nowarn -`. Skip the apply command for an empty decompressed patch.
4. Run `git write-tree` with that index and require equality with the snapshot tree in the manifest.
5. Create a new empty snapshot directory; use `git checkout-index --all --prefix=/absolute/snapshot/path/` with the same index. This writes the verified source files there.
6. Read that snapshot's AGENTS.md and applicable guides, then run the actual checks in the snapshot directory. Keep logs and proposed patches in `contribution-evidence/` inside the original cloud task checkout.

Do not change the developer's working tree while manipulating indexes. No test result is established by source-packet verification; execute the requested tests separately. Mark VM/rendering checks unavailable when unsupported, and continue with every check that can execute. Produce narrowly scoped upstream-ready test patches where useful; exclude this packet and investigation reports from any proposed upstream patch.
