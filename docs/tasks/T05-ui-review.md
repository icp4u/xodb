# T05 UI and rendering review

Goal: assess the working M0 UI against the fast native debugger direction and
produce specific, measured improvements. Own `docs/research/ui-review.md`.
Review source and the private-display smoke artifacts. Propose code changes;
keep `src/ui`, `src/render`, and `src/platform` with the coordinator for now.

## Scope

- Verify resize, font clipping, narrow panes, thread selection, source scrolling,
  divider dragging, and empty/running/stopped/exited states.
- Review Vulkan resource lifetime, synchronization, swapchain recreation, and
  how redraw cost changes with visible text and event counts.
- Measure a few meaningful timings on the workstation if tools are available;
  report the build mode, GPU, display configuration, and what the measurement
  actually includes. Do not infer frame performance from a screenshot.
- Recommend the smallest changes for keyboard navigation, readable dense data,
  scaling, and responsiveness. Keep the Zig/Wayland/Vulkan stack unless proposing
  a revision for the user's approval.

## Acceptance and handoff

Run `~/bin/bugme` before shared GPU work and use a private compositor following
`~/AGENTS.md`. Never drive the user's active desktop. Keep captures and logs in
a unique workdir folder and clean up your compositor and target processes.
Do not install Vulkan layers or system packages; report missing tools.

Return reproducible findings, annotated descriptions of relevant captures,
measured costs where available, and a ranked list of small changes. Distinguish
M0 defects from later docking, layout persistence, accessibility, and scaling
features. Record useful LLM-assisted interpretation ideas separately from
rendering correctness.
