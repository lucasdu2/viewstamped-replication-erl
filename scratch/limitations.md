# Limitations
To prevent this project from spiraling beyond the bounds of reasonable execution
(given my available time and limited ability), here are some limitations to
abide by. Hopefully, this will control things.
- No usage of gen_server (or any pre-built OTP abstractions). Do the simplest,
most direct thing that you can think of at all times. The code won't be as
bulletproof, but that's not the point of this exercise.
- The VR module should handle as much logic as possible. The user code should
only need to specify the callback functions on the server side (which will
communicate with the VR code) and the interface functions on the client side
(which will communicate with the VR proxy). Take inspiration from the
user-facing simplicity of gen_server.
- Forego any attempt at complete correctness. Come up with a test suite that you
would like to pass. Then mark this project as completed when the test suite
passes.
- Generally, best effort over completeness. The point of the exercise is to
implement the basic VR algorithm and work through some technical difficulties
in the process. It is not to implement a production-quality VR module that can
be used by others.
- Have a firm deadline to finish up. This should minimize any kind of "feature
creep" that might crop up. A month from now feels reasonable. Life is too short
to worry about perfection in a toy project.
