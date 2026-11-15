Ground truth for a review of `simpl-open-lab/ejbca-shim/main.go` (each item was verified by running the shim).

Real defects:
- G1 (weight 3): `initCA` ignores errors. If the persisted CA cert or key cannot be parsed (or any load step fails),
  it silently generates a NEW root CA and overwrites the persisted files, so every certificate issued before stops
  verifying. Ignored key-generation errors can also lead to a nil dereference. Count G1 if the review flags the
  ignored/swallowed errors in `initCA` or the silent CA regeneration/overwrite.
- G2 (weight 3): the OCSP nonce is not effectively echoed. `ocsp.CreateResponse` puts `ExtraExtensions` into the
  per-certificate singleExtensions, not the responseExtensions, so clients do not see a nonce in the response.
  Count G2 only if the review says the nonce ends up in the wrong place / is not returned where clients look /
  the library cannot add a response-level nonce (the comment at lines 77-78 hints at this).
- G3 (weight 1): revocation is fake: `revoke` / `revStatus` are stubs and/or the OCSP responder answers Good for
  every serial, including revoked or never-issued ones.
- G4 (weight 2): the Subject Key Identifier is the SHA-1 of the whole SubjectPublicKeyInfo, not of the
  subjectPublicKey BIT STRING as in RFC 5280 method 1 (what EJBCA does), contradicting the code comment.
- G5 (weight 1): the CA serial number is the constant 1, so a regenerated CA reuses the same issuer + serial.

False positives:
- FP1 (weight -2): claims the nonce VALUE is wrongly encoded, e.g. that it lacks the OCTET STRING tag/length or
  must be re-wrapped. (It is correctly encoded; the problem is where it is placed.)
- FP2 (weight -1): presents the missing authentication on enrollment as a high/critical defect without
  acknowledging it is a deliberate simplification of a lab tool bound to 127.0.0.1.
