"""OSBuild Manifest Pre-Processor"""


import sys
from .mpp import Mpp as Main


if __name__ == "__main__":
    with Main(sys.argv) as global_main:
        sys.exit(global_main.run())
