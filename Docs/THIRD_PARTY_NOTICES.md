# Third-Party Notices

## Secretive

AgenticFortress reviewed and adapted macOS Keychain and access-control design patterns from Secretive:

- Repository: <https://github.com/maxgoedjen/secretive>
- Copyright: Copyright (c) 2020 Max Goedjen
- License: MIT

Relevant adapted ideas:

- Use the data-protection Keychain for local secret material.
- Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Require explicit access-control flags for user presence or current biometric set.
- Carry an `LAContext` with a deterministic localized reason into Keychain reads.
- Keep code-signing and bundle identity stable because Keychain access is tied to app identity.
- Isolate risky parsing/IPC behind XPC-style boundaries.

The full MIT license text is reproduced below.

```text
MIT License

Copyright (c) 2020 Max Goedjen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
