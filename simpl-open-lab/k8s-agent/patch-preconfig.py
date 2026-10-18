#!/usr/bin/env python3
"""patch-preconfig.py <entrypoint.sh> > entrypoint.lab.sh

Adds an opt-in bootstrap marker to Simpl's ejbca-preconfig script. With EJBCA_BOOTSTRAP_MARKER set
to a path on EJBCA's persistent volume:
  * if the marker exists, the script exits at once: the CAs, profiles and ejbca-rest-api-secret were
    made by an earlier run, so there is no need to boot a whole EJBCA server to check;
  * it writes the marker when the set-up completes, and when it finds EJBCA already bootstrapped.
Without the variable the script is unchanged in behaviour.
"""
import sys

src = open(sys.argv[1]).read()
CHECK = '''  if [ -n "${EJBCA_BOOTSTRAP_MARKER:-}" ] && [ -f "$EJBCA_BOOTSTRAP_MARKER" ]; then
    echo "ejbca already bootstrapped (marker $EJBCA_BOOTSTRAP_MARKER)"
    exit 0
  fi

'''
MARK = '  if [ -n "${EJBCA_BOOTSTRAP_MARKER:-}" ]; then touch "$EJBCA_BOOTSTRAP_MARKER"; fi\n'

anchor = '  EJBCA_SH=/opt/keyfactor/bin/ejbca.sh\n'
assert src.count(anchor) == 1, "anchor: EJBCA_SH"
src = src.replace(anchor, CHECK + anchor)

already = '    echo "ejbca already bootstrapped"\n'
assert src.count(already) == 1, "anchor: already bootstrapped"
src = src.replace(already, already + "  " + MARK)

end = '\n}\n\ndo_it "$@"'
assert src.count(end) == 1, "anchor: end of do_it"
src = src.replace(end, '\n' + MARK + '}\n\ndo_it "$@"')
sys.stdout.write(src)
