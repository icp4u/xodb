# Short demo walkthroughs

## Emacs: Lisp and C at the same stop

Run `./scripts/demo-emacs` with a supported debug Emacs 31.1. Press **Space**,
select **Elisp**, then **xodb-demo-checkpoint**: its label is `"item"`.
Select the nearby **let** and scroll the bindings pane to find title
`"Profile delta"` and points `2`. The next **Space** shows `"Cache budget"`
and `3`; the next reaches `"render"`, with total `5` and dynamic stage
`"render"`. One more reaches the handled `"error"` case. The C argument link
lets you inspect the native caller beside those Lisp frames.

The demo transforms JSON into an Org-style outline using `cl-defun`, a lexical
lambda and `condition-case`. **Space** continues; **Shift+Q** quits. See the
[Emacs walkthrough](ELISP.md#try-the-demo) for executable overrides and current
limits, or the [Guide's demo table](GUIDE.md#try-it) for other runtimes.
