// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:analyzer/dart/analysis/context_locator.dart';
import 'package:analyzer/dart/analysis/context_root.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart'
    show PhysicalResourceProvider;
import 'package:analyzer/src/dart/analysis/context_root.dart';
import 'package:analyzer/src/task/options.dart';
import 'package:analyzer/src/util/yaml.dart';
import 'package:glob/glob.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart';
import 'package:yaml/yaml.dart';

/// An implementation of a context locator.
class ContextLocatorImpl implements ContextLocator {
  /// The name of the analysis options file.
  static const String ANALYSIS_OPTIONS_NAME = 'analysis_options.yaml';

  /// The name of the `.dart_tool` directory.
  static const String DOT_DART_TOOL_NAME = '.dart_tool';

  /// The name of the packages file.
  static const String PACKAGE_CONFIG_JSON_NAME = 'package_config.json';

  /// The name of the packages file.
  static const String DOT_PACKAGES_NAME = '.packages';

  /// The resource provider used to access the file system.
  final ResourceProvider resourceProvider;

  /// Initialize a newly created context locator. If a [resourceProvider] is
  /// supplied, it will be used to access the file system. Otherwise the default
  /// resource provider will be used.
  ContextLocatorImpl({ResourceProvider resourceProvider})
      : resourceProvider =
            resourceProvider ?? PhysicalResourceProvider.INSTANCE;

  @override
  List<ContextRoot> locateRoots(
      {@required List<String> includedPaths,
      List<String> excludedPaths,
      String optionsFile,
      String packagesFile}) {
    //
    // Compute the list of folders and files that are to be included.
    //
    List<Folder> includedFolders = <Folder>[];
    List<File> includedFiles = <File>[];
    _resourcesFromPaths(
        includedPaths ?? const <String>[], includedFolders, includedFiles);
    //
    // Compute the list of folders and files that are to be excluded.
    //
    List<Folder> excludedFolders = <Folder>[];
    List<File> excludedFiles = <File>[];
    _resourcesFromPaths(
        excludedPaths ?? const <String>[], excludedFolders, excludedFiles);
    //
    // Use the excluded folders and files to filter the included folders and
    // files.
    //
    includedFolders = includedFolders
        .where((Folder includedFolder) =>
            !_containedInAny(excludedFolders, includedFolder) &&
            !_containedInAny(includedFolders, includedFolder))
        .toList();
    includedFiles = includedFiles
        .where((File includedFile) =>
            !_containedInAny(excludedFolders, includedFile) &&
            !excludedFiles.contains(includedFile) &&
            !_containedInAny(includedFolders, includedFile))
        .toList();
    //
    // We now have a list of all of the files and folders that need to be
    // analyzed. For each, walk the directory structure and figure out where to
    // create context roots.
    //
    File defaultOptionsFile;
    if (optionsFile != null) {
      defaultOptionsFile = resourceProvider.getFile(optionsFile);
      if (!defaultOptionsFile.exists) {
        defaultOptionsFile = null;
      }
    }
    File defaultPackagesFile;
    if (packagesFile != null) {
      defaultPackagesFile = resourceProvider.getFile(packagesFile);
      if (!defaultPackagesFile.exists) {
        defaultPackagesFile = null;
      }
    }
    List<ContextRoot> roots = <ContextRoot>[];
    for (Folder folder in includedFolders) {
      ContextRootImpl root = ContextRootImpl(resourceProvider, folder);
      root.packagesFile = defaultPackagesFile ?? _findPackagesFile(folder);
      root.optionsFile = defaultOptionsFile ?? _findOptionsFile(folder);
      root.included.add(folder);
      root.excludedGlobs = _getExcludedGlobs(root);
      roots.add(root);
      _createContextRootsIn(roots, folder, excludedFolders, root,
          root.excludedGlobs, defaultOptionsFile, defaultPackagesFile);
    }
    Map<Folder, ContextRoot> rootMap = <Folder, ContextRoot>{};
    for (File file in includedFiles) {
      Folder parent = file.parent;
      ContextRoot root = rootMap.putIfAbsent(parent, () {
        ContextRootImpl root = ContextRootImpl(resourceProvider, parent);
        root.packagesFile = defaultPackagesFile ?? _findPackagesFile(parent);
        root.optionsFile = defaultOptionsFile ?? _findOptionsFile(parent);
        roots.add(root);
        return root;
      });
      root.included.add(file);
    }
    return roots;
  }

  /// Return `true` if the given [resource] is contained in one or more of the
  /// given [folders].
  bool _containedInAny(Iterable<Folder> folders, Resource resource) =>
      folders.any((Folder folder) => folder.contains(resource.path));

  /// If the given [folder] should be the root of a new analysis context, then
  /// create a new context root for it and add it to the list of context
  /// [roots]. The [containingRoot] is the context root from an enclosing
  /// directory and is used to inherit configuration information that isn't
  /// overridden.
  ///
  /// If either the [optionsFile] or [packagesFile] is non-`null` then the given
  /// file will be used even if there is a local version of the file.
  ///
  /// For each directory within the given [folder] that is neither in the list
  /// of [excludedFolders] nor excluded by the [excludedGlobs], recursively
  /// search for nested context roots.
  void _createContextRoots(
      List<ContextRoot> roots,
      Folder folder,
      List<Folder> excludedFolders,
      ContextRoot containingRoot,
      List<Glob> excludedGlobs,
      File optionsFile,
      File packagesFile) {
    //
    // If the options and packages files are allowed to be locally specified,
    // then look to see whether they are.
    //
    File localOptionsFile;
    if (optionsFile == null) {
      localOptionsFile = _getOptionsFile(folder);
    }
    File localPackagesFile;
    if (packagesFile == null) {
      localPackagesFile = _getPackagesFile(folder);
    }
    //
    // Create a context root for the given [folder] if at least one of the
    // options and packages file is locally specified.
    //
    if (localPackagesFile != null || localOptionsFile != null) {
      if (optionsFile != null) {
        localOptionsFile = optionsFile;
      }
      if (packagesFile != null) {
        localPackagesFile = packagesFile;
      }
      ContextRootImpl root = ContextRootImpl(resourceProvider, folder);
      root.packagesFile = localPackagesFile ?? containingRoot.packagesFile;
      root.optionsFile = localOptionsFile ?? containingRoot.optionsFile;
      root.included.add(folder);
      containingRoot.excluded.add(folder);
      roots.add(root);
      containingRoot = root;
      excludedGlobs = _getExcludedGlobs(root);
      root.excludedGlobs = excludedGlobs;
    }
    _createContextRootsIn(roots, folder, excludedFolders, containingRoot,
        excludedGlobs, optionsFile, packagesFile);
  }

  /// For each directory within the given [folder] that is neither in the list
  /// of [excludedFolders] nor excluded by the [excludedGlobs], recursively
  /// search for nested context roots and add them to the list of [roots].
  ///
  /// If either the [optionsFile] or [packagesFile] is non-`null` then the given
  /// file will be used even if there is a local version of the file.
  void _createContextRootsIn(
      List<ContextRoot> roots,
      Folder folder,
      List<Folder> excludedFolders,
      ContextRoot containingRoot,
      List<Glob> excludedGlobs,
      File optionsFile,
      File packagesFile) {
    bool isExcluded(Folder folder) {
      if (excludedFolders.contains(folder) ||
          folder.shortName.startsWith('.')) {
        return true;
      }
      for (Glob pattern in excludedGlobs) {
        if (pattern.matches(folder.path)) {
          return true;
        }
      }
      return false;
    }

    //
    // Check each of the subdirectories to see whether a context root needs to
    // be added for it.
    //
    try {
      for (Resource child in folder.getChildren()) {
        if (child is Folder) {
          if (isExcluded(child)) {
            containingRoot.excluded.add(child);
          } else {
            _createContextRoots(roots, child, excludedFolders, containingRoot,
                excludedGlobs, optionsFile, packagesFile);
          }
        }
      }
    } on FileSystemException {
      // The directory either doesn't exist or cannot be read. Either way, there
      // are no subdirectories that need to be added.
    }
  }

  /// Return the analysis options file to be used to analyze files in the given
  /// [folder], or `null` if there is no analysis options file in the given
  /// folder or any parent folder.
  File _findOptionsFile(Folder folder) {
    while (folder != null) {
      File optionsFile = _getOptionsFile(folder);
      if (optionsFile != null) {
        return optionsFile;
      }
      folder = folder.parent;
    }
    return null;
  }

  /// Return the packages file to be used to analyze files in the given
  /// [folder], or `null` if there is no packages file in the given folder or
  /// any parent folder.
  File _findPackagesFile(Folder folder) {
    while (folder != null) {
      File packagesFile = _getPackagesFile(folder);
      if (packagesFile != null) {
        return packagesFile;
      }
      folder = folder.parent;
    }
    return null;
  }

  /// Return a list containing the glob patterns used to exclude files from the
  /// given context [root]. The patterns are extracted from the analysis options
  /// file associated with the context root. The list will be empty if there are
  /// no exclusion patterns in the options file, or if there is no options file
  /// associated with the context root.
  List<Glob> _getExcludedGlobs(ContextRootImpl root) {
    List<Glob> patterns = [];
    File optionsFile = root.optionsFile;
    if (optionsFile != null) {
      try {
        String content = optionsFile.readAsStringSync();
        YamlNode doc = loadYamlNode(content);
        if (doc is YamlMap) {
          YamlNode analyzerOptions = getValue(doc, AnalyzerOptions.analyzer);
          if (analyzerOptions is YamlMap) {
            YamlNode excludeOptions =
                getValue(analyzerOptions, AnalyzerOptions.exclude);
            if (excludeOptions is YamlList) {
              List<String> excludeList = toStringList(excludeOptions);
              if (excludeList != null) {
                for (String excludedPath in excludeList) {
                  Context context = resourceProvider.pathContext;
                  if (context.isRelative(excludedPath)) {
                    excludedPath =
                        context.join(optionsFile.parent.path, excludedPath);
                  }
                  patterns.add(Glob(excludedPath, context: context));
                }
              }
            }
          }
        }
      } catch (exception) {
        // If we can't read and parse the analysis options file, then there
        // aren't any excluded files that need to be read.
      }
    }
    return patterns;
  }

  /// If the given [directory] contains a file with the given [name], then
  /// return the file. Otherwise, return `null`.
  File _getFile(Folder directory, String name) {
    Resource resource = directory.getChild(name);
    if (resource is File && resource.exists) {
      return resource;
    }
    return null;
  }

  /// Return the analysis options file in the given [folder], or `null` if the
  /// folder does not contain an analysis options file.
  File _getOptionsFile(Folder folder) =>
      _getFile(folder, ANALYSIS_OPTIONS_NAME);

  /// Return the packages file in the given [folder], or `null` if the folder
  /// does not contain a packages file.
  File _getPackagesFile(Folder folder) {
    var file = folder
        .getChildAssumingFolder(DOT_DART_TOOL_NAME)
        .getChildAssumingFile(PACKAGE_CONFIG_JSON_NAME);
    if (file.exists) {
      return file;
    }

    return _getFile(folder, DOT_PACKAGES_NAME);
  }

  /// Add to the given lists of [folders] and [files] all of the resources in
  /// the given list of [paths] that exist and are not contained within one of
  /// the folders.
  void _resourcesFromPaths(
      List<String> paths, List<Folder> folders, List<File> files) {
    for (String path in _uniqueSortedPaths(paths)) {
      Resource resource = resourceProvider.getResource(path);
      if (resource.exists && !_containedInAny(folders, resource)) {
        if (resource is Folder) {
          folders.add(resource);
        } else if (resource is File) {
          files.add(resource);
        } else {
          // Internal error: unhandled kind of resource.
        }
      }
    }
  }

  /// Return a list of paths that contains all of the unique elements from the
  /// given list of [paths], sorted such that shorter paths are first.
  List<String> _uniqueSortedPaths(List<String> paths) {
    Set<String> uniquePaths = HashSet<String>.from(paths);
    List<String> sortedPaths = uniquePaths.toList();
    sortedPaths.sort((a, b) => a.length - b.length);
    return sortedPaths;
  }
}
