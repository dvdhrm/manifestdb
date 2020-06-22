"""OSBuild Manifest Database"""


import sys
from .mdb import Mdb as Main


if __name__ == "__main__":
    with Main(sys.argv) as global_main:
        sys.exit(global_main.run())
