{
  lowPrio,
  newScope,
  pkgs,
  targetPackages,
  lib,
  stdenv,
  libxcrypt,
  substitute,
  replaceVars,
  fetchFromGitHub,
  fetchpatch,
  fetchpatch2,
  overrideCC,
  wrapCCWith,
  wrapBintoolsWith,
  buildPackages,
  buildLlvmTools, # tools, but from the previous stage, for cross
  targetLlvmLibraries, # libraries, but from the next stage, for cross
  targetLlvm,
  # This is the default binutils, but with *this* version of LLD rather
  # than the default LLVM version's, if LLD is the choice. We use these for
  # the `useLLVM` bootstrapping below.
  bootBintoolsNoLibc ? if stdenv.targetPlatform.linker == "lld" then null else pkgs.bintoolsNoLibc,
  bootBintools ? if stdenv.targetPlatform.linker == "lld" then null else pkgs.bintools,
  darwin,
  gitRelease ? null,
  officialRelease ? null,
  monorepoSrc ? null,
  version ? null,
  patchesFn ? lib.id,
  # Allows passthrough to packages via newScope. This makes it possible to
  # do `(llvmPackages.override { <someLlvmDependency> = bar; }).clang` and get
  # an llvmPackages whose packages are overridden in an internally consistent way.
  ...
}@args:

assert lib.assertMsg (lib.xor (gitRelease != null) (officialRelease != null)) (
  "must specify `gitRelease` or `officialRelease`"
  + (lib.optionalString (gitRelease != null) " — not both")
);

let
  monorepoSrc' = monorepoSrc;

  metadata = rec {
    # Import releaseInfo separately to avoid infinite recursion
    inherit
      (import ./common-let.nix {
        inherit (args)
          lib
          gitRelease
          officialRelease
          version
          ;
      })
      releaseInfo
      ;
    inherit (releaseInfo) release_version version;
    inherit
      (import ./common-let.nix {
        inherit
          lib
          fetchFromGitHub
          release_version
          gitRelease
          officialRelease
          monorepoSrc'
          version
          ;
      })
      llvm_meta
      monorepoSrc
      ;
    src = monorepoSrc;
    versionDir =
      (builtins.toString ../.)
      + "/${if (gitRelease != null) then "git" else lib.versions.major release_version}";
    getVersionFile =
      p:
      builtins.path {
        name = builtins.baseNameOf p;
        path =
          let
            patches = args.patchesFn (import ./patches.nix);

            constraints = patches."${p}" or null;
            matchConstraint =
              {
                before ? null,
                after ? null,
                path,
              }:
              let
                check = fn: value: if value == null then true else fn release_version value;
                matchBefore = check lib.versionOlder before;
                matchAfter = check lib.versionAtLeast after;
              in
              matchBefore && matchAfter;

            patchDir =
              toString
                (
                  if constraints == null then
                    { path = metadata.versionDir; }
                  else
                    (lib.findFirst matchConstraint { path = metadata.versionDir; } constraints)
                ).path;
          in
          "${patchDir}/${p}";
      };
  };

  tools = lib.makeExtensible (
    tools:
    let
      callPackage = newScope (tools // args // metadata);
      clangVersion =
        if (lib.versionOlder metadata.release_version "16") then
          metadata.release_version
        else
          lib.versions.major metadata.release_version;
      mkExtraBuildCommands0 =
        cc:
        ''
          rsrc="$out/resource-root"
          mkdir "$rsrc"
          echo "-resource-dir=$rsrc" >> $out/nix-support/cc-cflags
        ''
        # clang standard c headers are incompatible with FreeBSD so we have to put them in -idirafter instead of -resource-dir
        # see https://github.com/freebsd/freebsd-src/commit/f382bac49b1378da3c2dd66bf721beaa16b5d471
        + (
          if stdenv.targetPlatform.isFreeBSD then
            ''
              echo "-idirafter ${lib.getLib cc}/lib/clang/${clangVersion}/include" >> $out/nix-support/cc-cflags
            ''
          else
            ''
              ln -s "${lib.getLib cc}/lib/clang/${clangVersion}/include" "$rsrc"
            ''
        );
      mkExtraBuildCommandsBasicRt =
        cc:
        mkExtraBuildCommands0 cc
        + ''
          ln -s "${targetLlvmLibraries.compiler-rt-no-libc.out}/lib" "$rsrc/lib"
        '';
      mkExtraBuildCommands =
        cc:
        mkExtraBuildCommands0 cc
        + ''
          ln -s "${targetLlvmLibraries.compiler-rt.out}/lib" "$rsrc/lib"
          ln -s "${targetLlvmLibraries.compiler-rt.out}/share" "$rsrc/share"
        '';

      bintoolsNoLibc' = if bootBintoolsNoLibc == null then tools.bintoolsNoLibc else bootBintoolsNoLibc;
      bintools' = if bootBintools == null then tools.bintools else bootBintools;
    in
    {
      libllvm = callPackage ./llvm {
      };

      # `llvm` historically had the binaries.  When choosing an output explicitly,
      # we need to reintroduce `outputSpecified` to get the expected behavior e.g. of lib.get*
      llvm = tools.libllvm;

      tblgen = callPackage ./tblgen.nix {
        patches =
          builtins.filter
            # Crude method to drop polly patches if present, they're not needed for tblgen.
            (p: (!lib.hasInfix "-polly" p))
            tools.libllvm.patches;
        clangPatches = [
          # Would take tools.libclang.patches, but this introduces a cycle due
          # to replacements depending on the llvm outpath (e.g. the LLVMgold patch).
          # So take the only patch known to be necessary.
          (metadata.getVersionFile "clang/gnu-install-dirs.patch")
        ]
        ++
          lib.optional (stdenv.isAarch64 && lib.versions.major metadata.release_version == "17")
            # Fixes llvm17 tblgen builds on aarch64.
            # https://github.com/llvm/llvm-project/issues/106521#issuecomment-2337175680
            (metadata.getVersionFile "clang/aarch64-tblgen.patch");
      };

      libclang = callPackage ./clang {
      };

      clang-unwrapped = tools.libclang;

      llvm-manpages = lowPrio (
        tools.libllvm.override {
          enableManpages = true;
          python3 = pkgs.python3; # don't use python-boot
        }
      );

      clang-manpages = lowPrio (
        tools.libclang.override {
          enableManpages = true;
          python3 = pkgs.python3; # don't use python-boot
        }
      );

      # Wrapper for standalone command line utilities
      clang-tools = callPackage ./clang-tools { };

      # pick clang appropriate for package set we are targeting
      clang =
        if stdenv.targetPlatform.libc == null then
          tools.clangNoLibc
        else if stdenv.targetPlatform.useLLVM or false then
          tools.clangUseLLVM
        else if (pkgs.targetPackages.stdenv or args.stdenv).cc.isGNU then
          tools.libstdcxxClang
        else
          tools.libcxxClang;

      libstdcxxClang = wrapCCWith rec {
        cc = tools.clang-unwrapped;
        # libstdcxx is taken from gcc in an ad-hoc way in cc-wrapper.
        libcxx = null;
        extraPackages = [ targetLlvmLibraries.compiler-rt ];
        extraBuildCommands = mkExtraBuildCommands cc;
      };

      libcxxClang = wrapCCWith rec {
        cc = tools.clang-unwrapped;
        libcxx = targetLlvmLibraries.libcxx;
        extraPackages = [ targetLlvmLibraries.compiler-rt ];
        extraBuildCommands = mkExtraBuildCommands cc;
      };

      lld = callPackage ./lld {
      };

      lldbPlugins = lib.makeExtensible (
        lldbPlugins:
        let
          callPackage = newScope (lldbPlugins // tools // args // metadata);
        in
        lib.recurseIntoAttrs { llef = callPackage ./lldb-plugins/llef.nix { }; }
      );

      lldb = callPackage ./lldb (
        {
        }
        // lib.optionalAttrs (lib.versions.major metadata.release_version == "16") {
          src = callPackage (
            { runCommand }:
            runCommand "lldb-src-${metadata.version}" { } ''
              mkdir -p "$out"
              cp -r ${monorepoSrc}/cmake "$out"
              cp -r ${monorepoSrc}/lldb "$out"
            ''
          ) { };
        }
      );

      # Below, is the LLVM bootstrapping logic. It handles building a
      # fully LLVM toolchain from scratch. No GCC toolchain should be
      # pulled in. As a consequence, it is very quick to build different
      # targets provided by LLVM and we can also build for what GCC
      # doesn’t support like LLVM. Probably we should move to some other
      # file.

      bintools-unwrapped = callPackage ./bintools.nix { };

      bintoolsNoLibc = wrapBintoolsWith {
        bintools = tools.bintools-unwrapped;
        libc = targetPackages.preLibcHeaders;
      };

      bintools = wrapBintoolsWith { bintools = tools.bintools-unwrapped; };

      clangUseLLVM = wrapCCWith (
        rec {
          cc = tools.clang-unwrapped;
          libcxx = targetLlvmLibraries.libcxx;
          bintools = bintools';
          extraPackages = [
            targetLlvmLibraries.compiler-rt
          ]
          ++ lib.optionals (!stdenv.targetPlatform.isWasm && !stdenv.targetPlatform.isFreeBSD) [
            targetLlvmLibraries.libunwind
          ];
          extraBuildCommands =
            lib.optionalString (lib.versions.major metadata.release_version == "13") (
              ''
                echo "-rtlib=compiler-rt -Wno-unused-command-line-argument" >> $out/nix-support/cc-cflags
                echo "-B${targetLlvmLibraries.compiler-rt}/lib" >> $out/nix-support/cc-cflags
              ''
              + lib.optionalString (!stdenv.targetPlatform.isWasm) ''
                echo "--unwindlib=libunwind" >> $out/nix-support/cc-cflags
                echo "-L${targetLlvmLibraries.libunwind}/lib" >> $out/nix-support/cc-ldflags
              ''
              + lib.optionalString (!stdenv.targetPlatform.isWasm && stdenv.targetPlatform.useLLVM or false) ''
                echo "-lunwind" >> $out/nix-support/cc-ldflags
              ''
              + lib.optionalString stdenv.targetPlatform.isWasm ''
                echo "-fno-exceptions" >> $out/nix-support/cc-cflags
              ''
            )
            + mkExtraBuildCommands cc;
        }
        // lib.optionalAttrs (lib.versionAtLeast metadata.release_version "14") {
          nixSupport.cc-cflags = [
            "-rtlib=compiler-rt"
            "-Wno-unused-command-line-argument"
            "-B${targetLlvmLibraries.compiler-rt}/lib"
          ]
          ++ lib.optional (
            !stdenv.targetPlatform.isWasm && !stdenv.targetPlatform.isFreeBSD
          ) "--unwindlib=libunwind"
          ++ lib.optional (
            !stdenv.targetPlatform.isWasm
            && !stdenv.targetPlatform.isFreeBSD
            && stdenv.targetPlatform.useLLVM or false
          ) "-lunwind"
          ++ lib.optional stdenv.targetPlatform.isWasm "-fno-exceptions";
          nixSupport.cc-ldflags = lib.optionals (
            !stdenv.targetPlatform.isWasm && !stdenv.targetPlatform.isFreeBSD
          ) [ "-L${targetLlvmLibraries.libunwind}/lib" ];
        }
      );

      clangWithLibcAndBasicRtAndLibcxx = wrapCCWith (
        rec {
          cc = tools.clang-unwrapped;
          libcxx = targetLlvmLibraries.libcxx;
          bintools = bintools';
          extraPackages = [
            targetLlvmLibraries.compiler-rt-no-libc
          ]
          ++
            lib.optionals
              (
                !stdenv.targetPlatform.isWasm && !stdenv.targetPlatform.isFreeBSD && !stdenv.targetPlatform.isDarwin
              )
              [
                targetLlvmLibraries.libunwind
              ];
          extraBuildCommands =
            lib.optionalString (lib.versions.major metadata.release_version == "13") (
              ''
                echo "-rtlib=compiler-rt -Wno-unused-command-line-argument" >> $out/nix-support/cc-cflags
                echo "-B${targetLlvmLibraries.compiler-rt-no-libc}/lib" >> $out/nix-support/cc-cflags
              ''
              + lib.optionalString (!stdenv.targetPlatform.isWasm && !stdenv.targetPlatform.isDarwin) ''
                echo "--unwindlib=libunwind" >> $out/nix-support/cc-cflags
                echo "-L${targetLlvmLibraries.libunwind}/lib" >> $out/nix-support/cc-ldflags
              ''
              + lib.optionalString (!stdenv.targetPlatform.isWasm && stdenv.targetPlatform.useLLVM or false) ''
                echo "-lunwind" >> $out/nix-support/cc-ldflags
              ''
              + lib.optionalString stdenv.targetPlatform.isWasm ''
                echo "-fno-exceptions" >> $out/nix-support/cc-cflags
              ''
            )
            + mkExtraBuildCommandsBasicRt cc;
        }
        // lib.optionalAttrs (lib.versionAtLeast metadata.release_version "14") {
          nixSupport.cc-cflags = [
            "-rtlib=compiler-rt"
            "-Wno-unused-command-line-argument"
            "-B${targetLlvmLibraries.compiler-rt-no-libc}/lib"
          ]
          ++ lib.optional (
            !stdenv.targetPlatform.isWasm && !stdenv.targetPlatform.isFreeBSD && !stdenv.targetPlatform.isDarwin
          ) "--unwindlib=libunwind"
          ++ lib.optional (
            !stdenv.targetPlatform.isWasm
            && !stdenv.targetPlatform.isFreeBSD
            && stdenv.targetPlatform.useLLVM or false
          ) "-lunwind"
          ++ lib.optional stdenv.targetPlatform.isWasm "-fno-exceptions";
          nixSupport.cc-ldflags = lib.optionals (
            !stdenv.targetPlatform.isWasm && !stdenv.targetPlatform.isFreeBSD && !stdenv.targetPlatform.isDarwin
          ) [ "-L${targetLlvmLibraries.libunwind}/lib" ];
        }
      );

      clangWithLibcAndBasicRt = wrapCCWith (
        rec {
          cc = tools.clang-unwrapped;
          libcxx = null;
          bintools = bintools';
          extraPackages = [ targetLlvmLibraries.compiler-rt-no-libc ];
          extraBuildCommands =
            lib.optionalString (lib.versions.major metadata.release_version == "13") ''
              echo "-rtlib=compiler-rt" >> $out/nix-support/cc-cflags
              echo "-B${targetLlvmLibraries.compiler-rt-no-libc}/lib" >> $out/nix-support/cc-cflags
              echo "-nostdlib++" >> $out/nix-support/cc-cflags
            ''
            + mkExtraBuildCommandsBasicRt cc;
        }
        // lib.optionalAttrs (lib.versionAtLeast metadata.release_version "14") {
          nixSupport.cc-cflags = [
            "-rtlib=compiler-rt"
            "-B${targetLlvmLibraries.compiler-rt-no-libc}/lib"
            "-nostdlib++"
          ]
          ++ lib.optional (
            lib.versionAtLeast metadata.release_version "15" && stdenv.targetPlatform.isWasm
          ) "-fno-exceptions";
        }
      );

      clangNoLibcWithBasicRt = wrapCCWith (
        rec {
          cc = tools.clang-unwrapped;
          libcxx = null;
          bintools = bintoolsNoLibc';
          extraPackages = [ targetLlvmLibraries.compiler-rt-no-libc ];
          extraBuildCommands =
            lib.optionalString (lib.versions.major metadata.release_version == "13") ''
              echo "-rtlib=compiler-rt" >> $out/nix-support/cc-cflags
              echo "-B${targetLlvmLibraries.compiler-rt-no-libc}/lib" >> $out/nix-support/cc-cflags
            ''
            + mkExtraBuildCommandsBasicRt cc;
        }
        // lib.optionalAttrs (lib.versionAtLeast metadata.release_version "14") {
          nixSupport.cc-cflags = [
            "-rtlib=compiler-rt"
            "-B${targetLlvmLibraries.compiler-rt-no-libc}/lib"
          ]
          ++ lib.optional (
            lib.versionAtLeast metadata.release_version "15" && stdenv.targetPlatform.isWasm
          ) "-fno-exceptions";
        }
      );

      clangNoLibcNoRt = wrapCCWith (
        rec {
          cc = tools.clang-unwrapped;
          libcxx = null;
          bintools = bintoolsNoLibc';
          extraPackages = [ ];
          # "-nostartfiles" used to be needed for pkgsLLVM, causes problems so don't include it.
          extraBuildCommands = mkExtraBuildCommands0 cc;
        }
        // lib.optionalAttrs (lib.versionAtLeast metadata.release_version "14") {
          # "-nostartfiles" used to be needed for pkgsLLVM, causes problems so don't include it.
          nixSupport.cc-cflags = lib.optional (
            lib.versionAtLeast metadata.release_version "15" && stdenv.targetPlatform.isWasm
          ) "-fno-exceptions";
        }
      );

      # This is an "oddly ordered" bootstrap just for Darwin. Probably
      # don't want it otherwise.
      clangNoCompilerRtWithLibc =
        wrapCCWith rec {
          cc = tools.clang-unwrapped;
          libcxx = null;
          bintools = bintools';
          extraPackages = [ ];
          extraBuildCommands = mkExtraBuildCommands0 cc;
        }
        // lib.optionalAttrs (
          lib.versionAtLeast metadata.release_version "15" && stdenv.targetPlatform.isWasm
        ) { nixSupport.cc-cflags = [ "-fno-exceptions" ]; };

      # Aliases
      clangNoCompilerRt = tools.clangNoLibcNoRt;
      clangNoLibc = tools.clangNoLibcWithBasicRt;
      clangNoLibcxx = tools.clangWithLibcAndBasicRt;
    }
    // lib.optionalAttrs (lib.versionAtLeast metadata.release_version "15") {
      # TODO: pre-15: lldb/docs/index.rst:155:toctree contains reference to nonexisting document 'design/structureddataplugins'
      lldb-manpages = lowPrio (
        tools.lldb.override {
          enableManpages = true;
          python3 = pkgs.python3; # don't use python-boot
        }
      );
    }
    // lib.optionalAttrs (lib.versionAtLeast metadata.release_version "16") {
      mlir = callPackage ./mlir { };
    }
    // lib.optionalAttrs (lib.versionAtLeast metadata.release_version "19") {
      bolt = callPackage ./bolt {
      };
    }
    //
      lib.optionalAttrs
        (lib.versionAtLeast metadata.release_version "16" && lib.versionOlder metadata.release_version "20")
        {
          libclc = callPackage ./libclc { };
        }
  );

  libraries = lib.makeExtensible (
    libraries:
    let
      callPackage = newScope (
        libraries
        // buildLlvmTools
        // args
        // metadata
        # Previously monorepoSrc was erroneously not being passed through.
        // lib.optionalAttrs (lib.versionOlder metadata.release_version "14") { monorepoSrc = null; } # Preserve a bug during #307211, TODO: remove; causes llvm 13 rebuild.
      );
    in
    (
      {
        compiler-rt-libc = callPackage ./compiler-rt (
          let
            # temp rename to avoid infinite recursion
            stdenv =
              # Darwin needs to use a bootstrap stdenv to avoid an infinite recursion when cross-compiling.
              if args.stdenv.hostPlatform.isDarwin then
                overrideCC darwin.bootstrapStdenv buildLlvmTools.clangWithLibcAndBasicRtAndLibcxx
              else if args.stdenv.hostPlatform.useLLVM or false then
                overrideCC args.stdenv buildLlvmTools.clangWithLibcAndBasicRtAndLibcxx
              else
                args.stdenv;
          in
          {
            inherit stdenv;
          }
          // lib.optionalAttrs (stdenv.hostPlatform.useLLVM or false) {
            libxcrypt = (libxcrypt.override { inherit stdenv; }).overrideAttrs (old: {
              configureFlags = old.configureFlags ++ [ "--disable-symvers" ];
            });
          }
        );

        compiler-rt-no-libc = callPackage ./compiler-rt {
          doFakeLibgcc = stdenv.hostPlatform.useLLVM or false;
          stdenv =
            # Darwin needs to use a bootstrap stdenv to avoid an infinite recursion when cross-compiling.
            if stdenv.hostPlatform.isDarwin then
              overrideCC darwin.bootstrapStdenv buildLlvmTools.clangNoLibcNoRt
            else
              overrideCC stdenv buildLlvmTools.clangNoLibcNoRt;
        };

        compiler-rt =
          if
            stdenv.hostPlatform.libc == null
            # Building the with-libc compiler-rt and WASM doesn't yet work,
            # because wasilibc doesn't provide some expected things. See
            # compiler-rt's file for further details.
            || stdenv.hostPlatform.isWasm
            # Failing `#include <term.h>` in
            # `lib/sanitizer_common/sanitizer_platform_limits_freebsd.cpp`
            # sanitizers, not sure where to get it.
            || stdenv.hostPlatform.isFreeBSD
          then
            libraries.compiler-rt-no-libc
          else
            libraries.compiler-rt-libc;

        stdenv = overrideCC stdenv buildLlvmTools.clang;

        libcxxStdenv = overrideCC stdenv buildLlvmTools.libcxxClang;

        libcxx = callPackage ./libcxx (
          {
            stdenv =
              if stdenv.hostPlatform.isDarwin then
                overrideCC darwin.bootstrapStdenv buildLlvmTools.clangWithLibcAndBasicRt
              else
                overrideCC stdenv buildLlvmTools.clangWithLibcAndBasicRt;
          }
          // lib.optionalAttrs (lib.versionOlder metadata.release_version "14") {
            # TODO: remove this, causes LLVM 13 packages rebuild.
            inherit (metadata) monorepoSrc; # Preserve bug during #307211 refactor.
          }
        );

        libunwind = callPackage ./libunwind {
          stdenv = overrideCC stdenv buildLlvmTools.clangWithLibcAndBasicRt;
        };

        openmp = callPackage ./openmp {
        };
      }
      // lib.optionalAttrs (lib.versionAtLeast metadata.release_version "20") {
        libc-overlay = callPackage ./libc {
          isFullBuild = false;
          # Use clang due to "gnu::naked" not working on aarch64.
          # Issue: https://gcc.gnu.org/bugzilla/show_bug.cgi?id=77882
          stdenv = overrideCC stdenv buildLlvmTools.clang;
        };

        libc-full = callPackage ./libc {
          isFullBuild = true;
          # Use clang due to "gnu::naked" not working on aarch64.
          # Issue: https://gcc.gnu.org/bugzilla/show_bug.cgi?id=77882
          stdenv = overrideCC stdenv buildLlvmTools.clangNoLibcNoRt;
          cmake =
            if stdenv.targetPlatform.libc == "llvm" then buildPackages.cmakeMinimal else buildPackages.cmake;
          python3 =
            if stdenv.targetPlatform.libc == "llvm" then
              buildPackages.python3Minimal
            else
              buildPackages.python3;
        };

        libc = if stdenv.targetPlatform.libc == "llvm" then libraries.libc-full else libraries.libc-overlay;
      }
    )
  );

  noExtend = extensible: lib.attrsets.removeAttrs extensible [ "extend" ];
in
{
  inherit tools libraries;
  inherit (metadata) release_version;
}
// (noExtend libraries)
// (noExtend tools)
