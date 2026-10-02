import os
with open('lib/screens/profile/profile_wizard_screen.dart', 'r', encoding='utf-8') as f:
    lines = f.readlines()

changes = [
    # Instagram onChanged
    {
        'search': lambda line: 'ref.read(profileEditProvider(widget.user.id).notifier).updateInstagramUrl(val.trim());' in line,
        'before': '              onChanged: (val) {\n                ref.read(profileEditProvider(widget.user.id).notifier).updateInstagramUrl(val.trim());\n              },\n            ),\n          ),\n        ),',
        'after': '              onChanged: (val) {\n                ref.read(profileEditProvider(widget.user.id).notifier).updateInstagramUrl(val.trim());\n              },
            ),
          ),
        ),'
    },
]

# Actually, let us just do simple string replacements
with open('lib/screens/profile/profile_wizard_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# Replace Instagram onChanged
content = content.replace(
    "    onChanged: (val) {\n                ref.read(profileEditProvider(widget.user.id).notifier).updateInstagramUrl(val.trim());\n              },",
    "    onChanged: (val) {\n                final trimmed = val.trim();\n                ref.read(profileEditProvider(widget.user.id).notifier).updateInstagramUrl(trimmed.isNotEmpty ? trimmed : null);\n              },"
)

# Replace Facebook onChanged
content = content.replace(
    "    onChanged: (val) {\n                ref.read(profileEditProvider(widget.user.id).notifier).updateFacebookUrl(val.trim());\n              },",
    "    onChanged: (val) {\n                final trimmed = val.trim();\n                ref.read(profileEditProvider(widget.user.id).notifier).updateFacebookUrl(trimmed.isNotEmpty ? trimmed : null);\n              },"
)

# Replace LinkedIn onChanged
content = content.replace(
    "    onChanged: (val) {\n                ref.read(profileEditProvider(widget.user.id).notifier).updateLinkedinUrl(val.trim());\n              },",
    "    onChanged: (val) {\n                final trimmed = val.trim();\n                ref.read(profileEditProvider(widget.user.id).notifier).updateLinkedinUrl(trimmed.isNotEmpty ? trimmed : null);\n              },"
)

# We also need to add suffix icons. Let us do that by replacing the decoration blocks
# Instagram decoration - add suffixIcon after prefixIcon
old_insta = "                prefixIcon: const Icon(Icons.camera_alt_outlined),\n                border: InputBorder.none,"
new_insta = "                prefixIcon: const Icon(Icons.camera_alt_outlined),\n                suffixIcon: _instagramController.text.isNotEmpty\n                    ? IconButton(\n                        icon: const Icon(Icons.clear, size: 20),\n                        onPressed: () {\n                          _instagramController.clear();\n                          ref.read(profileEditProvider(widget.user.id).notifier).updateInstagramUrl(null);\n                        },\n                      )\n                    : null,\n                border: InputBorder.none,"
content = content.replace(old_insta, new_insta)

# Facebook decoration
old_fb = "                prefixIcon: const Icon(Icons.group),\n                border: InputBorder.none,"
new_fb = "                prefixIcon: const Icon(Icons.group),\n                suffixIcon: _facebookController.text.isNotEmpty\n                    ? IconButton(\n                        icon: const Icon(Icons.clear, size: 20),\n                        onPressed: () {\n                          _facebookController.clear();\n                          ref.read(profileEditProvider(widget.user.id).notifier).updateFacebookUrl(null);\n                        },\n                      )\n                    : null,\n                border: InputBorder.none,"
content = content.replace(old_fb, new_fb)

# LinkedIn decoration
old_linkedin = "                prefixIcon: const Icon(Icons.business_center_outlined),\n                border: InputBorder.none,"
new_linkedin = "                prefixIcon: const Icon(Icons.business_center_outlined),\n                suffixIcon: _linkedinController.text.isNotEmpty\n                    ? IconButton(\n                        icon: const Icon(Icons.clear, size: 20),\n                        onPressed: () {\n                          _linkedinController.clear();\n                          ref.read(profileEditProvider(widget.user.id).notifier).updateLinkedinUrl(null);\n                        },\n                      )\n                    : null,\n                border: InputBorder.none,"
content = content.replace(old_linkedin, new_linkedin)

with open('lib/screens/profile/profile_wizard_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)
print('Done')
