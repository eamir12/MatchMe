with open('lib/screens/profile/profile_wizard_screen.dart', encoding='utf-8') as f:
    content = f.read()

start_marker = 'Widget _buildSocialLinksSection'
end_marker = 'Widget _buildSocialLinksPage'

idx1 = content.find(start_marker)
idx2 = content.find(end_marker)

if idx1 == -1 or idx2 == -1:
    raise ValueError('Markers not found')

# Find the line start of idx1
line_start = content.rfind('\n', 0, idx1) + 1
# Find the line end of idx2
line_end = content.find('\n', idx2)

new_section = '''  Widget _buildSocialLinksSection(UserProfile profile, LocalizationState l10n) {
    final hasBusinessIntent = profile.activeModes.any((m) => _normalizeKey(m) == 'business_networking');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),

        // Instagram - for all users
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
          margin: const EdgeInsets.only(bottom: 14.0),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextFormField(
              controller: _instagramController,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: l10n.getString('profileInstagramUrl'),
                hintText: 'yourusername',
                prefixText: _instagramPrefix,
                prefixStyle: TextStyle(color: Colors.grey.shade500, fontSize: Theme.of(context).textTheme.bodySmall?.fontSize),
                prefixIcon: const Icon(Icons.camera_alt_outlined),
                suffixIcon: _instagramController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _instagramController.clear();
                          ref.read(profileEditProvider(widget.user.id).notifier).updateInstagramUrl(null);
                        },
                      )
                    : null,
                border: InputBorder.none,
              ),
              onChanged: (val) {
                final trimmed = val.trim();
                ref.read(profileEditProvider(widget.user.id).notifier).updateInstagramUrl(
                  trimmed.isNotEmpty ? '' : null,
                );
              },
            ),
          ),
        ),

        // Facebook - for all users
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
          margin: const EdgeInsets.only(bottom: 14.0),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextFormField(
              controller: _facebookController,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: l10n.getString('profileFacebookUrl'),
                hintText: 'yourusername',
                prefixText: _facebookPrefix,
                prefixStyle: TextStyle(color: Colors.grey.shade500, fontSize: Theme.of(context).textTheme.bodySmall?.fontSize),
                prefixIcon: const Icon(Icons.group),
                suffixIcon: _facebookController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _facebookController.clear();
                          ref.read(profileEditProvider(widget.user.id).notifier).updateFacebookUrl(null);
                        },
                      )
                    : null,
                border: InputBorder.none,
              ),
              onChanged: (val) {
                final trimmed = val.trim();
                ref.read(profileEditProvider(widget.user.id).notifier).updateFacebookUrl(
                  trimmed.isNotEmpty ? '' : null,
                );
              },
            ),
          ),
        ),

        // LinkedIn - only for business/networking intent
        if (hasBusinessIntent)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0), side: BorderSide(color: Colors.grey.shade200)),
            margin: const EdgeInsets.only(bottom: 14.0),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: TextFormField(
                controller: _linkedinController,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: l10n.getString('profileLinkedinUrl'),
                  hintText: 'yourprofile',
                  prefixText: _linkedinPrefix,
                  prefixStyle: TextStyle(color: Colors.grey.shade500, fontSize: Theme.of(context).textTheme.bodySmall?.fontSize),
                  prefixIcon: const Icon(Icons.business_center_outlined),
                  suffixIcon: _linkedinController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () {
                            _linkedinController.clear();
                            ref.read(profileEditProvider(widget.user.id).notifier).updateLinkedinUrl(null);
                          },
                        )
                      : null,
                  border: InputBorder.none,
                ),
                onChanged: (val) {
                  final trimmed = val.trim();
                  ref.read(profileEditProvider(widget.user.id).notifier).updateLinkedinUrl(
                    trimmed.isNotEmpty ? '' : null,
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
'''

new_content = content[:line_start] + new_section + content[line_end:]

with open('lib/screens/profile/profile_wizard_screen.dart', 'w', encoding='utf-8') as f:
    f.write(new_content)
