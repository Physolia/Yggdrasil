function glibc_sources(version)
    glibc_version_sources = Dict{VersionNumber,Vector}(
        v"2.12.2" => [
            ArchiveSource("https://mirrors.kernel.org/gnu/glibc/glibc-2.12.2.tar.xz",
                          "0eb4fdf7301a59d3822194f20a2782858955291dd93be264b8b8d4d56f87203f"),
        ],
        v"2.17" => [
            ArchiveSource("https://mirrors.kernel.org/gnu/glibc/glibc-2.17.tar.xz",
                          "6914e337401e0e0ade23694e1b2c52a5f09e4eda3270c67e7c3ba93a89b5b23e"),
        ],
        v"2.19" => [
            ArchiveSource("https://mirrors.kernel.org/gnu/glibc/glibc-2.19.tar.xz",
                          "2d3997f588401ea095a0b27227b1d50cdfdd416236f6567b564549d3b46ea2a2"),
        ],
        v"2.34" => [
            ArchiveSource("https://mirrors.kernel.org/gnu/glibc/glibc-2.34.tar.xz",
                          "44d26a1fe20b8853a48f470ead01e4279e869ac149b195dda4e44a195d981ab2"),
        ],
    )
    return [
        glibc_version_sources[version]...,
        # We've got a bevvy of patches for Glibc, include them in.
        DirectorySource("./bundled"; follow_symlinks=true),
    ]
end

function glibc_script()
    return raw"""
    cd $WORKSPACE/srcdir/glibc-*/

    # Some things need /lib64, others just need /lib
    case ${target} in
        x86_64*)
            lib64=lib64
            ;;
        aarch64*)
            lib64=lib64
            ;;
        ppc64*)
            lib64=lib64
            ;;
        *)
            lib64=lib
            ;;
    esac

    # Install licenses first thing
    install_license COPYING* LICENSES

    # Update configure scripts to work well with `musl`
    update_configure_scripts

    for p in ${WORKSPACE}/srcdir/patches/glibc-*.patch; do
        atomic_patch -p1 ${p}
    done

    # Various configure overrides
    GLIBC_CONFIGURE_OVERRIDES=( libc_cv_forced_unwind=yes libc_cv_c_cleanup=yes )

    # We have problems with libssp on ppc64le
    if [[ ${COMPILER_TARGET} == powerpc64le-* ]]; then
        GLIBC_CONFIGURE_OVERRIDES+=( libc_cv_ssp=no libc_cv_ssp_strong=no )
    fi

    mkdir -p $WORKSPACE/srcdir/glibc_build
    cd $WORKSPACE/srcdir/glibc_build
    $WORKSPACE/srcdir/glibc-*/configure \
        --prefix=/usr \
        --build=${MACHTYPE} \
        --host=${target} \
        --disable-multilib \
        --disable-werror \
        ${GLIBC_CONFIGURE_OVERRIDES[@]}

    make -j${nproc}
    make install install_root="${prefix}/${target}"

    # Copy our `crt*.o` files over (useful for bootstrapping GCC)
    csu_libdir="${prefix}/${target}/usr/${lib64}"
    cp csu/crt1.o csu/crti.o csu/crtn.o ${csu_libdir}/

    # fix bad linker scripts
    sed -i -e "s& /lib& ../lib&g" -e "s& /usr/${lib64}/& ./&g" "${csu_libdir}/libc.so"
    sed -i -e "s& /lib& ../lib&g" -e "s& /usr/${lib64}/& ./&g" "${csu_libdir}/libpthread.so"

    # Many Glibc versions place binaries in strange locations, this seems to be a build system bug
    if [[ -d ${prefix}/${target}/${prefix} ]]; then
        mv -v ${prefix}/${target}/${prefix}/* ${prefix}/
    fi
    """
end

function glibc_platforms(version)
    # Start with all glibc platforms
    platforms = filter(p -> libc(p) == "glibc", supported_platforms(;experimental=true))

    # Whittle down the platforms, depending on the minimum supported version of each
    function min_arch_version!(platforms, version, min_version, arches)
        if version < min_version
            filter!(p -> arch(p) ∉ arches, platforms)
        end
    end

    # v2.12.2 is the minimum version for x86_64, i686 support
    min_arch_version!(platforms, version, v"2.12.2", ("x86_64", "i686"))

    # v2.17 is the minimum version for ppc64le support
    min_arch_version!(platforms, version, v"2.17", ("powerpc64le",))

    # v2.19 is the minimum version of ARM support
    min_arch_version!(platforms, version, v"2.19", ("armv7l", "armv6l", "aarch64"))

    return platforms
end

function glibc_products()
    return Product[
        #LibraryProduct("libc", :libc; dont_dlopen=true),
        #LibraryProduct("libdl", :libld; dont_dlopen=true),
        #LibraryProduct("libm", :libm; dont_dlopen=true),
        #LibraryProduct("libpthread", :libpthread; dont_dlopen=true),
        #LibraryProduct("librt", :librt; dont_dlopen=true),
    ]
end

function glibc_dependencies()
    return []
end

# Somehow, we either need to allow GCC pulling in a Glibc of a different platform,
# or we need to do this automatically inside of `Glibc_jll`:
#
# using Pkg, Pkg.Artifacts
# artifacts_toml = "/home/sabae/.julia/dev/Glibc_jll/Artifacts.toml"
# arts = Artifacts.load_artifacts_toml(artifacts_toml)
# for (name, dicts) in arts
#     for d in dicts
#         if haskey(d, "target_arch")
#             continue
#         end
#         target_platform = Artifacts.unpack_platform(d, "", "")
#         encoded_platform = encode_target_platform(target_platform)
#         @info(name, target_platform, encoded_platform)
#         download_info = [(dl["url"], dl["sha256"]) for dl in d["download"]]
#         Artifacts.bind_artifact!(artifacts_toml, name, Base.SHA1(d["git-tree-sha1"]); platform=encoded_platform, download_info)
#     end
# end
