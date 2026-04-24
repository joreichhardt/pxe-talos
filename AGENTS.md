# Repository Guidelines

## Project Structure & Module Organization
`cloud-init/` contains the source fragments and variable files for the Pi image, `scripts/` holds the rendering, linting, and image-build entry points, `docs/` contains operational notes, and `build/` is generated output. Treat `build/` as disposable unless a workflow explicitly requires committed artifacts.

## Build, Test, and Development Commands
Run the shell entry points from the repository root.

- `scripts/render.sh` assembles cloud-init output into `build/`.
- `scripts/lint.sh` validates the generated configuration.
- `scripts/build-image.sh` downloads the Ubuntu Pi image and injects the generated files.
- `scripts/build-image.sh --device /dev/sdX` writes the built image directly to removable media after confirmation.

## Coding Style & Naming Conventions
Shell and cloud-init files should stay explicit and ops-friendly. Use uppercase names for environment-driven variables, keep defaults in `vars.env.defaults`, and keep local overrides in the ignored `vars.env.local`. Comment only where VLAN or PXE behavior is not obvious from the variable name.

## Testing Guidelines
For any change, rerun `scripts/render.sh` and `scripts/lint.sh`. If you alter image assembly, Talos asset fetching, DHCP, or Matchbox behavior, rebuild the image and perform a smoke test on the target hardware or a lab-equivalent setup. Never hand-edit generated files in `build/` as a substitute for fixing the source templates.

## Commit & Pull Request Guidelines
Recent history uses a mix of scoped imperative subjects such as `build-image: ...` and short direct summaries. Follow that pattern when a change is limited to one script or subsystem. PRs should mention VLAN, DHCP, image, or Talos bootstrap impact and list the exact validation steps performed.
