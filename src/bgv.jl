module BGV

    using Random
    using Distributions
    using GaloisFields
    using ..Karney
    using ..NTT

    import GaloisFields: PrimeField
    import ..Utils: @fields_as_locals
    export BGVParams

    import FHE: keygen, encrypt, decrypt, SHEShemeParams

    struct BGVParams <: SHEShemeParams
        # The Cypertext ring over which operations are performed
        ℛ
        # The plain modulus. Plaintexts are elements mod p.
        p
        σ
    end

    struct PrivKey
        params::BGVParams
        s
    end

    struct PubKey
        params::BGVParams
        a
        b
    end

    struct EvalKey
        params::BGVParams
        a
        b
    end

    struct KeyPair
        priv
        pub
    end

    struct CipherText{T}
        c::NTuple{2, T}
    end
    CipherText(c0::T, c1::T) where {T} = CipherText((c0, c1))
    Base.getindex(c::CipherText, i::Integer) = c.c[i]

    # HACK - DiscreteUniform is the default for types, but it'd be nice to
    # allow this.
    Distributions.DiscreteUniform(T::Type) = T

    function keygen(rng, params::BGVParams)
        @fields_as_locals params::BGVParams

        dug = RingSampler{ℛ}(DiscreteUniform(eltype(ℛ)))
        dgg = RingSampler{ℛ}(DiscreteNormal{eltype(ℛ)}(0, σ))

        a = nntt(rand(rng, dug))
        s = nntt(rand(rng, dgg))
        e = nntt(rand(rng, dgg))

        b = a*s + e*p

        KeyPair(PrivKey(params, s), PubKey(params, a, b))
    end
    keygen(params::BGVParams) = keygen(Random.GLOBAL_RNG, params)

    function encrypt(rng::AbstractRNG, key::PubKey, plaintext)
        @fields_as_locals key::PubKey
        @fields_as_locals params::BGVParams

        dgg = RingSampler{ℛ}(DiscreteNormal{eltype(ℛ)}(0, σ))

        v = nntt(rand(rng, dgg))
        e0 = nntt(rand(rng, dgg))
        e1 = nntt(rand(rng, dgg))

        c0 = b*v + p*e0 + plaintext
        c1 = a*v + p*e1
        CipherText(c0, c1)
    end
    encrypt(rng::AbstractRNG, kp::KeyPair, plaintext) = encrypt(rng, kp.pub, plaintext)
    encrypt(key, plaintext) = encrypt(Random.GLOBAL_RNG, key, plaintext)

    # TODO: This isn't fully generic
    function fqmod(e::PrimeField, modulus::Integer)
        halfq = GaloisFields.char(e)/2
        if e.n > halfq
            mod(e.n - GaloisFields.char(e), modulus)
        else
            mod(e.n, modulus)
        end
    end

    function decrypt(rng::AbstractRNG, key::PrivKey, c::CipherText)
        @fields_as_locals key::PrivKey
        @fields_as_locals params::BGVParams

        cc = inntt(c[1] - s*c[2])
        FixedDegreePoly(map(x->UInt8(fqmod(x, p)), cc.p.p))
    end
    decrypt(rng::AbstractRNG, kp::KeyPair, plaintext) = decrypt(rng, kp.priv, plaintext)
    decrypt(key, plaintext) = decrypt(Random.GLOBAL_RNG, key, plaintext)

    struct MultCipherText{T}
        c::NTuple{3,T}
    end

    function *(c1::CipherText, c2::CipherText)
        MultCipherText(
           c1[1] * c2[1],
           c1[1] * c2[2] + c1[2] * c2[1],
         -(c1[2] * c2[2])
        )
    end

    function keyswitch(ek::EvalKey, c::MultCipherText)
        @fields_as_locals ek::EvalKey
        # TODO
    end
end
