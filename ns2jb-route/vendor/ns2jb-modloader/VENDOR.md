# ns2jb-modloader (vendored)

From https://github.com/SebaaMG/ns2jb-modloader at 40b22746d8178a8369b0a1f5b19c5208243202d7, GPL-2.0 (LICENSE), with SeedSwap's
changes (the build that made SeedSwap's loader image):

     M lib/game-files/protocol.cjs
     M lib/lazy-context.cjs
     M lib/native.cjs
     M native/diagnostics.c
     M native/lazy-codefs.c
     M native/lazy-romfs.c
     M native/lazy.c
     M native/lazy.h
     M native/namespace.c
     M native/prebuilt/manifest.json
     M native/prebuilt/templates.json
     M native/verify-lazy.c

SeedSwap's ns2jb route uses lib/ (FS capture, Bridge, IPC session) and native/prebuilt (call
templates); native/ holds the sources the prebuilt files are checked against. lib/game-files is
derived from IZ2S-Platform/OunceCake (GPL-2.0, lib/game-files/COPYING).

## SHA-256

    f9c375a1be4a41f7b70301dd83c91cb89e41567478859b77eef375a52d782505  LICENSE
    30ed5722db224926f0636f5f3e05e4f3ea4e060785d5c01f49e5b7a0316f3be6  lib/codefs-identity.cjs
    87601ad67d1b5257d0aa8d3445ad9ee27ed7d6d55c6474007ac015d752ac4cbc  lib/common.cjs
    655d633f412cb58f65b1c102598bea38803766bd391b1af126f05d5ef5bbdb5f  lib/content.cjs
    b55f4eb309e2a19256abe56c53cb6b6f163159fa847446c90f0225ef5ca94d46  lib/context.cjs
    70f6dc31ef0c47cb5c6276087bc36e4b1b6cb1634d3688331829852706aa807d  lib/diagnostics.cjs
    c1c84dc453846fda0c2fbe41f08b0f1acd2caedde9dd713360bdc2ec46e449b2  lib/exefs.cjs
    813847bb5c0e813cfd83eab7046e8f111de90f3999a93651b0d957ba45a4db25  lib/find-session.cjs
    5c69127d38205d4cea382c80fc281d47ad67808cb09307afa9848020035eb73c  lib/game-cache.cjs
    f9c375a1be4a41f7b70301dd83c91cb89e41567478859b77eef375a52d782505  lib/game-files/COPYING
    647dc5026597170ae40c74b99a8d5d493e2da269c7915a27ba0e0f24035723a9  lib/game-files/content.cjs
    9c0d5a29e3140b8b588ec3e707eacfd7eee4516a9ab02e1b32565201bda7ecfd  lib/game-files/fs-context.cjs
    65611f9197ae21c4e09665519fb1299ac335379b88b43855a90dc850816ab93c  lib/game-files/io.cjs
    962a57e767cccfdc074b43b4d00d7e558e27722df35387a3197ff9b827c7e9af  lib/game-files/mount-api.cjs
    37c53f6619cddf01601e85a5e802f82a7a4d0f1f174d4a9dcee207645237475d  lib/game-files/mounts.cjs
    660a0d616be8789cac8cc38530a33693ebbcd440217c38f765a6a90c7c6460d0  lib/game-files/program.cjs
    3f19015e425688cb33f4b49e3925d304cdcec67327bbf676ec533b76d79c6405  lib/game-files/protocol.cjs
    9c861c17c45f4d447108a80b94c9aab7f9f665b1222567f2f07ab4e96c2f34e5  lib/game-files/session.cjs
    eb954bc81d4549e3e1d373e12969ded66e24e05e90bab895236a76ea87fac1ee  lib/game-files/uncertain.cjs
    92817f780c3ad7d2d933c33a3dab2c1bb2a29b8fb544f890c88f655e141534e8  lib/host-path.cjs
    eb54ceb0918dba0b1004539317444d3fe772c1e836feed9b15406356772d23c2  lib/lazy-context.cjs
    5a73b0e7a267ca3f528429ff9b256c510c64142100c4dccca46148c45b37614e  lib/lz4.cjs
    3f3b07a42a082daa4056094b57209a51386c39fd23af89f115061e65e3530c30  lib/mods.cjs
    14eddd9817f7221c8e23f58afb688e0e65617aead199a462f572c6e44c0f73fb  lib/native/artifacts.cjs
    77e8d932a9615578c04d682637478fb71057e0e07409049f1ee695e1e2209ee6  lib/native/bridge.cjs
    31fe1b652eda40208cc519e35d6a3b5b3683f1d30aa4a8e1529736d2488cfcfa  lib/native/call-source.cjs
    37c6a111a535a6d76d4230c7145c7c259a02cb3eba244482bfe4c16d7080a46c  lib/native/capture.cjs
    6fd4522e8606fd6ea04f2fbc7626e00a0cdf18a50a7388946b45d850dafcc035  lib/native/client.cjs
    67a2d0c4d03bdcaad3fb7398f8bcd0612c1ecee1f42b3d8573518aae1cb37510  lib/native/elf-text.cjs
    1a14ec93dcd2d77b7be0ae34184995d0e9e37aed31a7aeac78fc1a9d57f5d921  lib/native/fs-abi.cjs
    7553d7e244d32e7d162087b0b3c8aa5bdc2c6177a25e7850400e97ef89168ab9  lib/native/fs-abi.json
    f01499e9235e97730c4e797b9d2e888f6cfe291acee552ad9dae66fd07aab224  lib/native/fs-contract.json
    f065f3000cf278dc44bece12a2b6a7509f374784a5bd53e465df9c1116cd46e7  lib/native/fs-layout.cjs
    d28b9c6013c0d660bc8b5b326fba206737858e9886bae357d1745c8dcb4bb8c4  lib/native/handoff.cjs
    547512b24cbef07c19edbf003aea935a3a11637a5cf0eddd8fde1d1ddf855ef8  lib/native/identity.cjs
    d44b66beea4b3a5d07fdba385fb6d612b5839158ee4bb209334253b63bbc4a9e  lib/native/inventory.cjs
    d37d05e8d8cbaa52a54f5ff8de314298b7b09995f499018d317a0bbbfc043419  lib/native/source.cjs
    7c28b1912a3c202ab1c0470a841c21a98df7a86c87fb455199bf5e5e1974c27d  lib/native/stock-ro-health.cjs
    ecf3df7c2b0b1ea6c94bc93f8d691d1b4a45b527a8ed77564f151c73fd0192cf  lib/native/verify.cjs
    6faf53118463601332baef916d69241da34b1ac1d815f2fbe89de2d51950f8cd  lib/native-capture.cjs
    1b785cf81626e0fc21dac4628c7f78aede692d6e78464dbea7e0479f56e09d27  lib/native-namespace.cjs
    8ca6528ab161e9ab69aa6f42a544b1207c458f69c7492141bf96c4028f3133b4  lib/native.cjs
    704d1104854ad5c8c0f9d08fa40e601df97b843594dfcbe2b2eb4e0304969a79  lib/nso-delta.cjs
    09669d954e968f253f0dd39ca963e4f6a7eb2940cd51ff982d4dce737c25c1fe  lib/pack.cjs
    8cb662e1fe2c09d543ca193e542c98afe2fc4756f710fc70b8353de051fb3730  lib/patch-input.cjs
    6da6fd48f93f95d56d37742add00a8e438dcbfcc5ad952f8a4ddf9bc66cbe243  lib/pchtxt.cjs
    ca13d9cc6a11c1d4c3f5f6793c60a86aadd36733c1c5b06fb37da95d53b8ebc1  lib/pfs.cjs
    6bfa1e6be56cf3b596884e3e1681847b3886400fae99216340baeb6681bd13db  lib/prepare.cjs
    49917f6b3dffe6ca81e1e36d3923799f2328c2d2fac34a8d05a41940d0428cdd  lib/resident.cjs
    eade78bb576d3b9a74737ef1a742f99be0d9caa54b6168ef46aa1eae24329c8c  lib/romfs.cjs
    b973482a006eed207da17b3192b09cb3e4bbe90a05948977d91a571b00dd4358  lib/sd-mods.cjs
    4a994cb58f041d46bba3d23153929b0df0a93fe520370a8589ae2c70dd157b55  lib/setup-diagnostics.cjs
    98a9e77491c5519a2f1bcc9bd2777b8b503c431191df12d5dd2d4ccde5c385c5  lib/sources.cjs
    6a833aceb4cc92fd13ae9e636f25aca5bd1ca2173ad015aac816f66f85495e55  lib/static-views.cjs
    c024eb6c87cb80dd717c498d5de27a178846f8e5f16fa89f085b7c07414e5da8  lib/upload.cjs
    a6954a2a1f10b6145d77ae60ae9b8399bb1fd63c2c9e31acfc7dc3af7d81c680  lib/verify-plan.cjs
    4f6f1e41cd72694355faad9f124c5568b74dfd318ea5110fa8695975fba0186e  lib/zbic.cjs
    4fe84f9e663baf56669308e6b7aeb302435e5672ae669888e45046d278d86a83  native/capture.c
    f6314ce1fe3ca989470d8963cc624266d770717a7db377f66ddf09b7e35f8e19  native/diagnostics.c
    bf6f56a2cc516048024dca2b44089774884b785598868b7e8d64245f29732f99  native/inventory.c
    e6b5c6f51552f28fe198e3da3adbd5e1c4a825b1d52070650b504d0de9514c7a  native/lazy-codefs.c
    a02f91adcf4dd5dbbd89e7b91314e9d79fca2ef13c50ed115c97a9f14204e37f  native/lazy-nso.c
    bda597daa79ee2f5e5b759244d13f502f743048f16bb40a621a98f023cdea99f  native/lazy-romfs.c
    242e9eeff29898a3c094058513c11cc7b2d5f161fa82b561ca27724c799c2c72  native/lazy.c
    b193be07095b2cbcff89d09496def644aa5a36924ddab0b2f054c94f2a763163  native/lazy.h
    bc252849bc0897e6c4371cae46a5233f785336eaa8b68678ed77ec23e95d55e4  native/minilibc.c
    d94561bd03d5427ed0f775d11e65d60274c8f6ae132812604845fc5012c6b69a  native/namespace.S
    601e64d73fbf00cc1b5fb31343bc98c8fc01312fdb1463a9ae78053c31942639  native/namespace.c
    e771cdfee8ce51d0e0df21f6a8ed8e8282f82c17e58c8df8e28b3afb2654cd0e  native/namespace.h
    309573830ad36356cbf76e6117e1b6394266a6e12457a37a7f85c2c0e6e54a0b  native/prebuilt/manifest.json
    5e4280252a16be4e2a837adb206bde476c4ef4d184bed09c1f451feff7abf61f  native/prebuilt/templates.json
    332a0d964cdad308777f3c5d8732e2fa452a81858a008ec323a745ab7e4e763d  native/prebuilt/zbic.wasm
    1423135ba611b633bbf9fde04115dd8a72dc0fd77883017c23301b2f83761aaa  native/romfs.c
    a83e60850ad907b1cfc5a4eae1a6ac582a8956867a4bb08b82409150609388b8  native/trace.c
    cea25a788be3d03859371dcf1ee24ad7183032ab6a6effbfaf5f992facf6e4ce  native/trace.h
    371de203806079e9a1b4fbdad5bf72df8d5fbb659144c2a8ee394f3e3ef9f28c  native/vendor/freestanding/assert.h
    0e14f5afbb70fd231ed475f87206b1f71283b1d8c81a0f90e12fdfc09409b782  native/vendor/freestanding/stdio.h
    2ec29eedbd5fb2b98d364d2fa4302c4e616bc8203cee41d84805358d16af572d  native/vendor/freestanding/stdlib.h
    5b59567875af97387bb546efb14d84c1e9b35db7846d3dab3a57943c001e9654  native/vendor/freestanding/string.h
    c88d0d62cbec91922c054ac64cbc308412cf9304b51a2a3fb7b32d5f8b50be83  native/vendor/freestanding/time.h
    c8b789cf5a746611e6300a0cc7750dbf92b61912a709d04e639245f7290656d0  native/vendor/wasi/CLOUDLIBC-LICENSE
    673f577e363e80e0058bd78214683f045d1d0c63930969a87f01a1d87d7cf1d6  native/vendor/wasi/LICENSE
    23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3  native/vendor/wasi/LICENSE-MIT
    f9bc4423732350eb0b3f7ed7e91d530298476f8fec0c6c427a1c04ade22655af  native/vendor/wasi/MUSL-COPYRIGHT
    93da773afc198f1ea0ff23f1f8f58654b9a99e517f725e76f86b2710a8b7ce41  native/vendor/wasi/NOTICE
    f9c375a1be4a41f7b70301dd83c91cb89e41567478859b77eef375a52d782505  native/vendor/zstd/COPYING
    171d1076d0a8e76d60a18491106f4ebfd1011be2fb85d5dd37e36eb1c0356735  native/vendor/zstd/NOTICE
    4cd9bf41ead4f59b0380a5668b9b018010f5a7a893a2948e0ab84e1653a08b38  native/vendor/zstd/zstd.inc
    ca617f7905a7b5b797be4b8e4148bd8e4a7c3ab807696b893975dc2970dbd4f1  native/verify-lazy.c
    3b75f361e3e0b96496a810984a7892ff33666f4ff38925f88cde434073fd0912  native/verify.c
    c985903401d03432a97e82bf8847ae268c8a23c314a7c1724f906809350ca981  native/verify.py
    e0b6459511e6294032bc42a19bd8bc7fa6bec5f4afde1bc6d669db72dbb6d4e0  native/zbic-cli.c
    c5ed7aefc496f583b297a6e48d7ab81937ec17f64a14b0ec9aa295abffd537c1  native/zbic-native.c
