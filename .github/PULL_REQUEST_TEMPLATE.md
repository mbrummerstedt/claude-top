**What this changes, and why.**

**How it was tested.** This project is written test-first. Which test did you write, and
did you watch it fail before writing the code?

**Fixture counts.** `swift test` pins the reference capture to specific numbers. If your
change moved any of them, say which and why. Sometimes that is correct, and it is never
correct for it to happen quietly.

**Checklist**

- [ ] `swift test` passes
- [ ] No new third-party dependencies
- [ ] Anything shelling out has a timeout and degrades to "unknown"
- [ ] No reap selection widened beyond env stamp and Compose `working_dir`
- [ ] Nothing new persists a session prompt
- [ ] Prose reads as though a person wrote it (see CONTRIBUTING.md)
