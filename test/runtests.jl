
# Trivial BFV, scalar encoding small plaintext space, pow2 cyclotomic ring
include("bfv_triv.jl")

# Trivial BGV
include("bgv_triv.jl")

# BFV with p=65537 SIMD over cyclotomic ring
include("bfv_simd.jl")

# No encryption, just thest the PolyCRT encoding code
include("polycrt_encoding.jl")

# BFV with p=256 SIMD over non-cyclotomic ring
include("bfv_uint8.jl")

# Keyswitching for BFV
include("bfv_keyswitch.jl")

# Noise measurement for bfv
include("bfv_noise.jl")

# BFV with CRT representation
include("bfv_crt.jl")

# CKKS
include("ckks_triv.jl")

include("ckks_modswitch.jl")

include("ckks_rotate.jl")

include("ckks_matmul.jl")

include("ckks_modraise.jl")
