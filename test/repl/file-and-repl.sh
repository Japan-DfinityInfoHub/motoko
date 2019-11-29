#!/bin/bash
${MOC:-$(dirname "$BASH_SOURCE")/../../src/moc} -v -i \
  <(echo "let x = 1; switch (true) {case true ()}") <<__END__
assert (x == 1);
__END__
