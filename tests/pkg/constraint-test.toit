import expect show *
import ...tools.pkg.semantic-version
import ...tools.pkg.constraints

check-constraint v/string c/string:
  expect --message="$v$c"
      (Constraint c).satisfies
          SemanticVersion v

check-not-constraint v/string c/string:
  expect-not --message="not $v$c"
      (Constraint c).satisfies
          SemanticVersion v

main:
  check-constraint "2.1.2" "^2.1.1"
  check-constraint "2.1.1" "^2.1.1"
  check-constraint "2.9.1" "^2.1.1"

  check-constraint "2.1.2" "~2.1.1"
  check-constraint "2.1.6" "~2.1.1"

  check-constraint "2.1.2" ">=2.1.1"
  check-constraint "2.1.1" ">=2.1.1"
  check-constraint "3.1.1" ">=2.1.1"

  check-constraint "2.1.2" "<2.2.1"
  check-constraint "2.1.2" "<3.2.1"

  check-constraint "2.1.2" ">2.1.1"
  check-constraint "3.1.2" ">2.2.1"

  check-constraint "2.2.1" "<=2.2.1"
  check-constraint "1.2.1" "<=2.2.1"
  check-constraint "2.2.1" "=2.2.1"

  check-constraint "2.2.1" "2.2.1"
  check-constraint "5.2.1" "=5.2.1"


  check-not-constraint "2.1.0" "^2.1.1"
  check-not-constraint "3.1.0" "^2.1.1"
  check-not-constraint "2.2.0" "~2.1.1"
  check-not-constraint "3.1.0" "=2.1.1"
  check-not-constraint "3.1.0" "3.1.1"
  check-not-constraint "2.1.1-alpha" "^2.1.1"