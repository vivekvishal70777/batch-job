%dw 2.0
import dw::Crypto
output application/java
---
Crypto::hashWith(write(payload, "application/json") as Binary, "SHA-256") as String {base: "hex"}
