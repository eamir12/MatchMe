import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'scripts'))
import fix_appbar_titles as m  # noqa: E402

m.ROOT = os.path.abspath(os.path.join('matchme_admin', 'lib'))
m.IMPORT = "import 'package:matchme_admin/widgets/safe_text.dart';"
m.main()
