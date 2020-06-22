#!/bin/bash
export PYTHONPATH="${PYTHONPATH:+${PYTHONPATH}:}./src"
python3 -m mdb "$@"
