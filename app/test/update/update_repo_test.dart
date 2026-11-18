// The build-time release repository override (tooling/build-apk.sh sets it to
// this fork): every metadata and download URL must follow it, while project
// links stay on the upstream repository.

import 'package:dsh_app/update/update_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _repo = String.fromEnvironment('DSH_UPDATE_REPO', defaultValue: 'ccch1mneyyy/dsh-go');

void main() {
  test('release URLs follow the configured repository', () {
    expect(updateRepo, _repo);
    expect(
      githubLatestAsset(updateManifestName).toString(),
      'https://github.com/$_repo/releases/latest/download/$updateManifestName',
    );
    expect(
      githubReleaseAsset('v1.2.1-resultonly.1', 'dsh-go-1.2.1-resultonly.1-arm64.apk').toString(),
      'https://github.com/$_repo/releases/download/v1.2.1-resultonly.1/dsh-go-1.2.1-resultonly.1-arm64.apk',
    );
    expect(
      defaultUpdateSources().metadataEndpoints().map((endpoint) => endpoint.url.toString()),
      contains(githubLatestAsset(updateManifestName).toString()),
    );
  });

  test('the project page is always the upstream repository', () {
    expect(projectRepo, 'ccch1mneyyy/dsh-go');
  });
}
