default:
    @just --list

test:
    crystal spec

fmt:
    crystal tool format src spec

check:
    crystal tool format --check src spec
    crystal spec
