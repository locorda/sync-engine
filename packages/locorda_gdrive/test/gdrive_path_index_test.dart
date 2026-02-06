import 'package:flutter_test/flutter_test.dart';
import 'package:locorda_gdrive/src/gdrive_backend.dart';

void main() {
  test('GDrivePathIndex describes file IDs by path', () {
    final index = GDrivePathIndex();

    index.registerEntry(const GDriveListedEntry(
      fileId: 'folder-id',
      path: 'notes',
      isFolder: true,
    ));
    index.registerEntry(const GDriveListedEntry(
      fileId: 'file-id',
      path: 'notes/doc.ttl',
      isFolder: false,
    ));

    expect(index.describeFileId('file-id'), 'notes/doc.ttl');
    expect(index.describeFileId('missing'), 'missing');
  });

  test('GDrivePathIndex builds child paths from folder ids', () {
    final index = GDrivePathIndex();
    index.registerFolderId('parent-id', 'root/folder');

    expect(
      index.buildChildPath(parentId: 'parent-id', name: 'child.ttl'),
      'root/folder/child.ttl',
    );

    expect(
      index.buildChildPath(parentId: 'unknown', name: 'child.ttl'),
      'child.ttl',
    );
  });
}
