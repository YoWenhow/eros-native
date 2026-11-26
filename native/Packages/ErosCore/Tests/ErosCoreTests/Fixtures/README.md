# Parser fixtures

The corpus contains 68 input and expected-result pairs for ErosCore parser tests. Inputs use synthetic hosts and cover designed cases, cases based on legacy source, and redacted captures. The manifest records each fixture's provenance and semantic coverage. Capture entries identify the sanitized input by its SHA-256.

Run the suite from the native directory with the following command.

    bash scripts/test-core.sh

Swift Package Manager attaches this directory only to the ErosCore test target.
