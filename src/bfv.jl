module BFV

    using Random
    using Distributions
    using GaloisFields
    using ..NTT
    using ..CryptParameters
    using Primes
    using BitIntegers
    using Nemo
    using AbstractAlgebra
    using Mods

    import GaloisFields: PrimeField
    import ..Utils: @fields_as_locals, fqmod, plaintext_space
    import ..ToyFHE: SHEShemeParams, RingSampler, modulus, degree, SignedMod
    export BFVParams

    import ToyFHE: keygen, encrypt, decrypt, coefftype
    import Base: +, *, -

    struct BFVParams <: SHEShemeParams
        # The Cypertext ring over which operations are performed
        ℛ
        # The big ring used during multiplication
        ℛbig
        # The plaintext ring.
        ℛplain
        relin_window
        σ
        Δ
    end

    plaintext_space(p::BFVParams) = p.ℛplain

    # Matches parameter generation in PALISADE
    function BFVParams(p, σ=8/√(2π), α=9, r=1; eval_mult_count = 0, security = HEStd_128_classic, relin_window=1)
        @assert r >= 1
        Berr = σ*√(α)
        Bkey = Berr
        δ(n) = 2*√(n)
        Vnorm(n) = Berr * (1 + 2*δ(n)*Bkey)

        function nRLWE(q)
            if isa(security, StdSecurity)
                CryptParameters.std_ring_dim(HEStd_error, security, ceil(log2(q)))
            else
                # The security parameter is interpreted as the hermite factor as
                # in PALISADE.
                log2(q / σ) / (4 * log2(security));
            end
        end

        n = 512
        q = 0

        if eval_mult_count > 0
            w = 2^r
            ϵ₁(n) = 4 / δ(n)*Bkey
            C₁(n) = (1 + ϵ₁(n))*δ(n)^2*p*Bkey
            C₂(n, qPrev) =
                δ(n)^2*p*Bkey*(Bkey + p^2) +
                δ(n)*(floor(log2(qPrev) / r) + 1)*w*Berr
            qBFV(n, qPrev) =
                p^2 + 2p*(
                    C₁(n)^eval_mult_count * Vnorm(n) +
                    eval_mult_count*C₁(n)^(eval_mult_count-1)*C₂(n, qPrev))

            qPrev = 1e6
            q = qBFV(n, qPrev)
            qPrev = q

            while nRLWE(q) > n
                while nRLWE(q) > n
                    n *= 2
                    # TODO: So in original, but is this right?
                    # Shouldn't we set qPrev = q first.
                    q = qBFV(n, qPrev)
                    qPrev = q
                end

                q = qBFV(n, qPrev)

                while abs(q - qPrev) > 0.001q
                    qPrev = q
                    q = qBFV(n, qPrev)
                end
            end
        end

        qPrime = nextprime(Int128(2)^(ceil(Int, log2(q))+1) + 1, 1; interval=2n)
        largebits = 2*ceil(Int, log2(q)) + ceil(Int, log2(p)) + 3
        Tlarge = largebits > 128 ? Int256 : Int128
        qLargeBig = nextprime(big(2)^largebits + 1, 1; interval=2n)
        qPrimeLarge = Tlarge(qLargeBig)

        Δ = div(qPrime, p)

        𝔽 = GaloisField(qPrime)
        ℛ = NegacyclicRing{𝔽, n}(GaloisFields.minimal_primitive_root(𝔽, 2n))
        𝔽big = GaloisField(qPrimeLarge)
        r = GaloisFields.minimal_primitive_root(𝔽big, 2n)
        ℛbig = NegacyclicRing{𝔽big, n}(r)

        BFVParams(ℛ, ℛbig, plaintext_space(ℛ, p), relin_window, σ, Δ)
    end

    struct PrivKey
        params::BFVParams
        s
    end

    struct PubKey
        params::BFVParams
        a
        b
    end

    struct EvalKey
        params::BFVParams
        a
        b
    end

    struct KeyPair
        priv
        pub
    end
    Base.show(io::IO, kp::KeyPair) = print(io, "BFV key pair")

    struct CipherText{T, N}
        params::BFVParams
        cs::NTuple{N, T}
    end
    Base.length(c::CipherText) = length(c.cs)
    Base.getindex(c::CipherText, i::Integer) = c.cs[i]
    Base.lastindex(c::CipherText) = length(c)

    function keygen(rng, params::BFVParams)
        @fields_as_locals params::BFVParams

        dug = RingSampler(ℛ, DiscreteUniform(coefftype(ℛ)))
        dgg = RingSampler(ℛ, DiscreteNormal(0, σ))

        a = rand(rng, dug)
        s = rand(rng, dgg)
        e = rand(rng, dgg)

        KeyPair(
            PrivKey(params, s),
            PubKey(params, a, -(a*s + e)))
    end

    function make_eval_key(rng::AbstractRNG, ::Type{EvalKey}, (old, new)::Pair{<:Any, PrivKey})
        @fields_as_locals new::PrivKey
        @fields_as_locals params::BFVParams

        dug = RingSampler(ℛ, DiscreteUniform(coefftype(ℛ)))
        dgg = RingSampler(ℛ, DiscreteNormal(0, σ))

        nwindows = ndigits(modulus(coefftype(ℛ)), base=2^relin_window)
        evala = [old * coefftype(params.ℛ)(2)^(i*relin_window) for i = 0:nwindows-1]
        evalb = eltype(evala)[]

        for i = 1:length(evala)
            a = rand(rng, dug)
            e = rand(rng, dgg)
            push!(evalb, a)
            evala[i] -= a*new.s + e
        end
        EvalKey(new.params, evala, evalb)
    end
    keygen(rng::AbstractRNG, ::Type{EvalKey}, priv::PrivKey) = make_eval_key(rng, EvalKey, priv.s^2=>priv)
    keygen(::Type{EvalKey}, priv::PrivKey) = keygen(Random.GLOBAL_RNG, EvalKey, priv)

    function encrypt(rng::AbstractRNG, key::PubKey, plaintext)
        @fields_as_locals key::PubKey
        @fields_as_locals params::BFVParams

        dgg = RingSampler(ℛ, DiscreteNormal(0, σ))

        u = rand(rng, dgg)
        e₁ = rand(rng, dgg)
        e₂ = rand(rng, dgg)

        c₁ = b*u + e₁ + Δ * oftype(u, ℛplain(plaintext))
        c₂ = a*u + e₂

        return CipherText(params, (c₁, c₂))
    end
    encrypt(rng::AbstractRNG, kp::KeyPair, plaintext) = encrypt(rng, kp.pub, plaintext)
    encrypt(key::KeyPair, plaintext) = encrypt(Random.GLOBAL_RNG, key, plaintext)

    for f in (:+, :-)
        @eval function $f(c1::CipherText{T,N1}, c2::CipherText{T,N2}) where {T,N1,N2}
            CipherText((
                i > length(c1) ? c2[i] :
                i > length(c2) ? c1[i] :
                $f(c1[i], c2[i]) for i in max(N1, N2)))
        end
    end

    function multround(e::SignedMod, a::Integer, b::Integer)
        div(e * a, b, RoundNearestTiesAway)
    end
    function multround(e::BigInt, a::Integer, b::Integer)
        div(e * a, b, RoundNearestTiesAway)
    end
    multround(e, a::Integer, b::fmpz) = multround(e, a, BigInt(b))
    multround(e::fmpz, a::Integer, b::Integer) = multround(BigInt(e), a, b)
    multround(e::fmpz, a::Integer, b::fmpz) = multround(BigInt(e), a, BigInt(b))

    function multround(e, a::Integer, b)
        oftype(e, broadcast(NTT.coeffs_primal(e)) do x
            if isa(x, AbstractAlgebra.Generic.Res{fmpz})
                multround(BigInt(Nemo.lift(x)), a, b)
            else
                multround(SignedMod(x), a, b).x
            end
        end)
    end

    Nemo.modulus(e::PrimeField) = GaloisFields.char(e)
    Nemo.lift(e::PrimeField) = e.n
    Nemo.lift(e::Nemo.nmod) = lift(Nemo.ZZ, e)

    divround(e::Integer, q::Integer) = div(e, q, RoundNearestTiesAway)
    divround(e::fmpz, q::Integer) = divround(BigInt(e), q)
    function divround(e, d::Integer)
        div(SignedMod(e), d, RoundNearestTiesAway)
    end


    function switchel(T, e)
        q = modulus(e)
        halfq = q >> 1
        diff = modulus(T) > q ? modulus(T) - q : q - modulus(T)
        en = convert(Integer, e)
        if (q < modulus(T))
            if en > halfq
                return T(en + diff)
            else
                return T(en)
            end
        else
            if en > halfq
                return T(en - diff)
            else
                return T(en)
            end
        end
    end

    function switch(ℛ, e)
        ℛ(broadcast(NTT.coeffs_primal(e)) do x
            switchel(coefftype(ℛ), x)
        end)
    end

    function *(c1::CipherText{T}, c2::CipherText{T}) where {T}
        params = c1.params
        @fields_as_locals params::BFVParams

        modswitch(c) = switch(ℛbig, c)
        c1 = map(modswitch, c1.cs)
        c2 = map(modswitch, c2.cs)

        c = [zero(c1[1]) for i = 1:(length(c1) + length(c2) - 1)]
        for i = 1:length(c1), j = 1:length(c2)
            c[i+j-1] += c1[i] * c2[j]
        end

        c = map(c) do e
            switch(ℛ, multround(e, modulus(base_ring(ℛplain)), modulus(coefftype(ℛ))))
        end

        CipherText(params, (c...,))
    end

    function decrypt(key::PrivKey, c::CipherText)
        @fields_as_locals key::PrivKey
        @fields_as_locals params::BFVParams

        b = c[1]
        spow = s

        for i = 2:length(c)
            b += spow*c[i]
            spow *= s
        end

        ℛplain = plaintext_space(params)
        ℛplain(map(x->coefftype(ℛplain)(convert(Integer, mod(divround(x, Δ), modulus(base_ring(ℛplain))))), NTT.coeffs_primal(b)))
    end
    decrypt(key::KeyPair, plaintext) = decrypt(key.priv, plaintext)

    function keyswitch(ek::EvalKey, c::CipherText)
        @fields_as_locals ek::EvalKey
        @fields_as_locals params::BFVParams
        @assert length(c.cs) in (2,3)
        nwindows = ndigits(modulus(coefftype(ℛ)), base=2^relin_window)

        c1 = c[1]
        c2 = length(c) == 2 ? zero(c[2]) : c[2]

        cendcoeffs = NTT.coeffs_primal(c[end])
        ds = map(cendcoeffs) do x
            digits(x.n, base=2^params.relin_window, pad=nwindows)
        end
        ps = map(1:nwindows) do i
            ℛ([coefftype(ℛ)(ds[j][i]) for j in eachindex(cendcoeffs)])
        end

        for i in eachindex(a)
            c2 += b[i] * ps[i]
            c1 += a[i] * ps[i]
        end

        CipherText(ek.params, (c1, c2))
    end

    """
    Compute the *invariant noise budget*, defined by:

            -log2(2‖v‖) = log2(q) - log2(q‖v‖) - 1.

    If this quantity is >0, the ciphertext is expected to decrypt correctly with
    high probability.

    This notion of noise was first introduced by the SEAL HE library. See [CLP19]
    for details.

    [CLP19] Anamaria Costache, Kim Laine, and Rachel Player
            "Homomorphic noise growth in practice: comparing BGV and FV"
            https://eprint.iacr.org/2019/493.pdf
    """
    function invariant_noise_budget(pk::PrivKey, c::CipherText)
        @fields_as_locals pk::PrivKey
        @fields_as_locals params::BFVParams

        b = c[1]
        spow = s

        for i = 2:length(c)
            b += spow*c[i]
            spow *= s
        end

        ℛplain = plaintext_space(params)

        function birem(x)
            r = rem(x, Δ)
            if r > div(Δ, 2)
                return Δ - r
            else
                return r
            end
        end

        # -log2(2‖v‖) = log(q) - log(t) - 1 - max_i log2(Δ |v_i|)
        log2(modulus(coefftype(ℛ))) - log2(modulus(coefftype(ℛplain))) - 1 -
            maximum(log2(birem(c.n)) for c in NTT.coeffs_primal(b))
    end
    invariant_noise_budget(kp::KeyPair, c::CipherText) =
        invariant_noise_budget(kp.priv, c)
end
