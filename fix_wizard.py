with open('lib/screens/profile/profile_wizard_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# Update Instagram onChanged
old_insta = "              onChanged: (val) {\n                ref.read(profileEditProvider(widget.user.id).notifier).updateInstagramUrl(val.trim());\n              },\n            ),\n          ),\n        ),"
new_insta = "              onChanged: (val) {\n                final trimmed = val.trim();\n                ref.read(profileEditProvider(widget.user.id).notifier).updateInstagramUrl(\n                  trimmed.isNotEmpty ? trimmed : null,\n                );\n              },\n            ),\n          ),\n        ),"
content = content.replace(old_insta, new_insta)

# Update Facebook onChanged
old_fb = "              onChanged: (val) {\n                ref.read(profileEditProvider(widget.user.id).notifier).updateFacebookUrl(val.trim());\n              },\n            ),\n          ),\n        ),"
new_fb = "              onChanged: (val) {\n                final trimmed = val.trim();\n                ref.read(profileEditProvider(widget.user.id).notifier).updateFacebookUrl(\n                  trimmed.isNotEmpty ? trimmed : null,\n                );\n              },\n            ),\n          ),\n        ),"
content = content.replace(old_fb, new_fb)

# Update LinkedIn onChanged
old_lin = "              onChanged: (val) {\n                ref.read(profileEditProvider(widget.user.id).notifier).updateLinkedinUrl(val.trim());\n              },\n            ),\n          ),\n        ),"
new_lin = "              onChanged: (val) {\n                final trimmed = val.trim();\n                ref.read(profileEditProvider(widget.user.id).notifier).updateLinkedinUrl(\n                  trimmed.isNotEmpty ? trimmed : null,\n                );\n              },\n            ),\n          ),\n        ),"
content = content.replace(old_lin, new_lin)

# Add Instagram suffix icon
old_insta_dec = "                prefixIcon: const Icon(Icons.camera_alt_outlined),\n                border: InputBorder.none,"
new_insta_dec = "                prefixIcon: const Icon(Icons.camera_alt_outlined),\n                suffixIcon: _instagramController.text.isNotEmpty\n                    ? IconButton(\n                        icon: const Icon(Icons.clear, size: 20),\n                        onPressed: () {\n                          _instagramController.clear();\n                          ref.read(profileEditProvider(widget.user.id).notifier).updateInstagramUrl(null);\n                        },\n                      )\n                    : null,\n                border: InputBorder.none,"
content = content.replace(old_insta_dec, new_insta_dec)

# Add Facebook suffix icon
old_fb_dec = "                prefixIcon: const Icon(Icons.group),\n                border: InputBorder.none,"
new_fb_dec = "                prefixIcon: const Icon(Icons.group),\n                suffixIcon: _facebookController.text.isNotEmpty\n                    ? IconButton(\n                        icon: const Icon(Icons.clear, size: 20),\n                        onPressed: () {\n                          _facebookController.clear();\n                          ref.read(profileEditProvider(widget.user.id).notifier).updateFacebookUrl(null);\n                        },\n                      )\n                    : null,\n                border: InputBorder.none,"
content = content.replace(old_fb_dec, new_fb_dec)

# Add LinkedIn suffix icon
old_lin_dec = "                prefixIcon: const Icon(Icons.business_center_outlined),\n                border: InputBorder.none,"
new_lin_dec = "                prefixIcon: const Icon(Icons.business_center_outlined),\n                suffixIcon: _linkedinController.text.isNotEmpty\n                    ? IconButton(\n                        icon: const Icon(Icons.clear, size: 20),\n                        onPressed: () {\n                          _linkedinController.clear();\n                          ref.read(profileEditProvider(widget.user.id).notifier).updateLinkedinUrl(null);\n                        },\n                      )\n                    : null,\n                border: InputBorder.none,"
content = content.replace(old_lin_dec, new_lin_dec)

with open('lib/screens/profile/profile_wizard_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)

print('Done')
