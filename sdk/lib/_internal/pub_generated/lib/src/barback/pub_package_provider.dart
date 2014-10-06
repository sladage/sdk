library pub.pub_package_provider;
import 'dart:async';
import 'package:barback/barback.dart';
import 'package:path/path.dart' as path;
import '../io.dart';
import '../package_graph.dart';
import '../preprocess.dart';
import '../sdk.dart' as sdk;
import '../utils.dart';
class PubPackageProvider implements StaticPackageProvider {
  final PackageGraph _graph;
  final List<String> staticPackages;
  Iterable<String> get packages =>
      _graph.packages.keys.toSet().difference(staticPackages.toSet());
  PubPackageProvider(PackageGraph graph)
      : _graph = graph,
        staticPackages = [
          r"$pub",
          r"$sdk"]..addAll(graph.packages.keys.where(graph.isPackageStatic));
  Future<Asset> getAsset(AssetId id) {
    final completer0 = new Completer();
    scheduleMicrotask(() {
      try {
        join0() {
          join1() {
            var nativePath = path.fromUri(id.path);
            var file = _graph.packages[id.package].path(nativePath);
            _assertExists(file, id);
            completer0.complete(new Asset.fromPath(id, file));
          }
          if (id.package == r'$sdk') {
            var parts = path.split(path.fromUri(id.path));
            assert(parts.isNotEmpty && parts[0] == 'lib');
            parts = parts.skip(1);
            var file = path.join(sdk.rootDirectory, path.joinAll(parts));
            _assertExists(file, id);
            completer0.complete(new Asset.fromPath(id, file));
          } else {
            join1();
          }
        }
        if (id.package == r'$pub') {
          var components = path.url.split(id.path);
          assert(components.isNotEmpty);
          assert(components.first == 'lib');
          components[0] = 'dart';
          var file = assetPath(path.joinAll(components));
          _assertExists(file, id);
          join2() {
            var versions =
                mapMap(_graph.packages, value: ((_, package) => package.version));
            var contents = readTextFile(file);
            contents = preprocess(contents, versions, path.toUri(file));
            completer0.complete(new Asset.fromString(id, contents));
          }
          if (!_graph.packages.containsKey("barback")) {
            completer0.complete(new Asset.fromPath(id, file));
          } else {
            join2();
          }
        } else {
          join0();
        }
      } catch (e0) {
        completer0.completeError(e0);
      }
    });
    return completer0.future;
  }
  void _assertExists(String path, AssetId id) {
    if (!fileExists(path)) throw new AssetNotFoundException(id);
  }
  Stream<AssetId> getAllAssetIds(String packageName) {
    if (packageName == r'$pub') {
      var dartPath = assetPath('dart');
      return new Stream.fromIterable(
          listDir(
              dartPath,
              recursive: true).where(
                  (file) => path.extension(file) == ".dart").map((library) {
        var idPath = path.join('lib', path.relative(library, from: dartPath));
        return new AssetId('\$pub', path.toUri(idPath).toString());
      }));
    } else if (packageName == r'$sdk') {
      var libPath = path.join(sdk.rootDirectory, "lib");
      return new Stream.fromIterable(
          listDir(
              libPath,
              recursive: true).where((file) => path.extension(file) == ".dart").map((file) {
        var idPath =
            path.join("lib", path.relative(file, from: sdk.rootDirectory));
        return new AssetId('\$sdk', path.toUri(idPath).toString());
      }));
    } else {
      var package = _graph.packages[packageName];
      return new Stream.fromIterable(
          package.listFiles(beneath: 'lib').map((file) {
        return new AssetId(
            packageName,
            path.toUri(package.relative(file)).toString());
      }));
    }
  }
}