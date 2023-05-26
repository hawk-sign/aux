from sage.all import ceil, e, floor, Infinity, IntegerRange, load, log, pi, \
        RR, sqrt, var, find_fit, show
from proba_utils import centered_discrete_Gaussian_law, law_square, \
        law_convolution, iter_law_convolution, pos_head_probability, \
        tail_probability
#  predict_beta_and_prev_sd and predict_sign_forge_beta from this load
load("BKZ_simulator.sage")


def slog(x, base):
    """
    A ``safe`` log for dealing with log of float(0.0)

    :param x:       input to the log
    :param base:    the base to take the logarithm
    :returns:       either log(x, base) or -inf

    .. note::       -Infinity here is really some approximation of how strictly
                    cutoff is set in clean_dist of proba_utils -- in the paper
                    we rather arbitrarily set -Infinity as -300
    """
    if x > 0.0:
        return log(x, base)
    return -Infinity


def rhf(beta):
    """
    The root Hermite factor for BKZ with blocksize at least 50

    :param beta:    an integer blocksize for BKZ
    :returns:       the root Hermite factor as a float
    """
    small = (( 2, 1.02190),  # noqa
             ( 5, 1.01862),  # noqa
             (10, 1.01616),
             (15, 1.01485),
             (20, 1.01420),
             (25, 1.01342),
             (28, 1.01331),
             (40, 1.01295))

    beta = float(beta)
    if beta <= 2:
        return (1.0219)
    elif beta < 40:
        for i in range(1, len(small)):
            if small[i][0] > beta:
                return (small[i-1][1])
    elif beta == 40:
        return (small[-1][1])
    return float(((beta/(2.*pi*e))*(pi*beta)**(1./beta))**(1/(2.*(beta-1))))


def log_gsa_lens(d, beta, vol=1, first=True):
    """
    The (natural) log of the Gram--Schmidt basis vector lengths after reduction
    according to the Geometric Series Assumption and the root Hermite factor

    :param d:       an integer dimension
    :param beta:    an integer blocksize <= d for BKZ
    :param vol:     the volume of the lattice being reduced
    :param first:   a bool that if set means only the first Gram--Schmidt
                        length is returned
    :returns:       a list of log lengths for the Gram--Schmidt basis vectors

    ..note::        the root Hermite factor + GSA model for the lengths of
                    Gram--Schmidt vectors gives the same as [MW16, Cor 2] that
                    is commonly used elsewhere
    """
    assert d.is_integer() and d > 0, "the dimension must be a positive int"
    assert beta <= d, "require beta <= d"
    assert vol > 0, "the lattice volume must be positive"
    assert isinstance(first, bool), "first must be a bool"

    rhf_beta = rhf(beta)
    if first:
        return [(d - 1.)*log(rhf_beta) + (1./d) * log(vol)]
    return [(d-2.*i-1.)*log(rhf_beta) + (1./d) * log(vol) for i in range(d)]


def approx_SVP_beta(d, sver, simulate=True):
    """
    Estimating the blocksize beta required to find an approximate short
    vector of square length d * sver**2 for ZZ^d

    :param d:       an integer dimension
    :param sver:    a standard deviation controlling the length of acceptable
                        signatures (equivalently, the distance from a target)
    :returns:       the estimated beta for a (strong) signature forgery
    """
    assert sver > 0, "standard deviation sver must be positive"

    if simulate:
        # we scale the lattice by sqrt(d), as sver determines the length of the
        # lattice vector to be discovered, it must be similarly scaled
        beta = predict_sign_forge_beta(d, d*log(d)/2, sqrt(d) * sver) # noqa
        return beta

    log_sqr_ver_bound = float(2.*log(sver) + log(d))
    success_beta = None
    for beta in IntegerRange(50, d):
        log_first_sqr = 2. * log_gsa_lens(d, beta)[0]
        if success_beta is None and log_first_sqr <= log_sqr_ver_bound:
            return beta


def keyRecoveryADPSstyle(d, k_fac=False):
    """
    Following the ADPS methodology, i.e. without simulation using the leaky-LWE
    estimator.

    :param d:       an integer dimension
    :param k_fac:   include a multiplicative factor of (4/3)**.5 in rhs, as in
                    FALCON (just for testing)
    :returns:       a blocksize ``beta``
    """
    for beta in [2, 5, 10, 15, 20, 25, 28, 40] + list(range(41, d)):
        lhs = (beta / d)**.5
        rhs = rhf(beta)**(2*beta-d+1)
        if k_fac:
            rhs *= (4./3.)**.5
        if lhs <= rhs:
            return beta


def key_recovery_beta_ssec(d, tours=1):
    """
    Use the leaky-LWE-estimator to determine the expected successful blocksize
    that recovers a lattice vector of length one from some basis of ZZ^d, along
    with the length of the shortest vector found before the vector of length
    one i.e. len = ssec * sqrt(d)

    :param d:       an integer dimension
    :param tours:   a number of tours to simulate in progressive BKZ
    :returns:       ``beta`` an estimate for the required blocksize for key
                        recovery, and ``ssec``the estimates the length of
                        the previous shortest vector
    """
    beta, ssec = predict_beta_and_prev_sd(d, d*log(d)/2, lift_union_bound=True,
                                          number_targets=d, tours=tours)
    # lattice was scaled up, so ssec need to be scaled back
    ssec /= sqrt(d)
    return beta, ssec


def findBetaSsec(d, simulate=False, simulatessec=False, tours=1):
    """
    An attempt to find the standard deviation at which dimension d instances
    exhibit maximum hardness, based on the idea that if ||(f, g)|| is longer
    than the first basis we expect after lattice reduction by successful beta,
    then we are in the regime where our lattice reduction heuristics hold

    :param d:               an integer dimension
    :param simulate:        if ``False`` use ADPS methodology, else leaky-LWE
    :param simulatessec:    if True simulate ssec
    :param tours:           a number of tours to simulate in progressive BKZ
    :returns:           a standard deviation (not Gaussian width) sigma and the
                        beta we expect to represent maximum hardness
    """
    if simulate:
        beta, ssec = key_recovery_beta_ssec(d, tours=tours)
    else:
        beta = keyRecoveryADPSstyle(d)
    if not simulate or not simulatessec:
        ssec = (rhf(beta)**(d-1.))/d**.5
    return beta, ssec


def modelssec(drange, simulate=False, simulatessec=False, tours=1):
    """
    Gives a model for the growth of sigma_sec as the dimension grows, via
    various levels of simulation.
    If both flags are False we estimate the first length before canonical
    discovery as

        rhf(beta)^(d-1) for minimal beta such that
            sqrt(beta/d) <= rhf(beta)^(2 beta - d + 1)

    and therefore return ssec = rhf(beta)^(d-1) / sqrt(d)
    If simulate is True we simulate the minimal beta and calculate ssec as
    above, if simulate and simulatessec are True then we take ssec directly
    from simulation

    :param drange:          the range of dimensions to compute the model over
    :param simulate:        if True simulate beta
    :param simulatessec:    if True simulate ssec
    :param tours:           a number of tours to simulate in progressive BKZ


    ..note::    we expect a model of the shape a * d^.5 + b, for some b in
                o(d^.5) as a sufficient blocksize is d/2 + o(d)

    ..note::    for ssec in our actual scheme we use simulation, rather than
                this fit
    """
    data = []
    for d in drange:
        if simulate and simulatessec:
            _, ssec = findBetaSsec(d, simulate=True, simulatessec=True,
                                   tours=tours)
        elif simulate and not simulatessec:
            _, ssec = findBetaSsec(d, simulate=True, simulatessec=False,
                                   tours=tours)
        elif not simulate and not simulatessec:
            _, ssec = findBetaSsec(d, simulate=False)
        else:
            raise NotImplementedError
        data += [(d, ssec)]

    var('a', 'b', 'x')
    # concretise b to a constant, arguable
    model(x) = a*sqrt(x) + b # noqa
    sol = find_fit(data, model)
    return sol


def statistical_ssign(d, lam, q_s):
    """
    Determine the minimum value of the standard deviation controlling the
    Gaussian sampler within Sign, via [Sec. 2.6, FALCON] considering ZZ^d

    :param d:       an integer dimension
    :param lam:     a security parameter
    :param q_s:     the number of signature queries allowed to an adversary
    :returns:       a standard deviation
    """
    assert d.is_integer() and d > 0, "the dimension must be a positive int"
    assert lam > 0, "the security parameter must be positive"
    assert q_s.is_integer() and q_s > 0, "q_s must be a positive int"
    eps = 1/sqrt(q_s * lam)
    ssign = (1/pi) * sqrt(log((2*d)*(1 + 1/eps)) / 2)
    return RR(ssign)


def failProbability(d, ssign, sver, A2_d=None):
    """
    Determines the probability that signing fails because x is too long

    :param ssign:       a standard deviation controlling the length of elements
                            sampling during signing
    :param sver:        a standard deviation controlling the length of
                            acceptable signatures
    :returns:           log2 of the above failure probability
    """
    sqr_radius = d * sver**2.

    if A2_d is None:
        A = centered_discrete_Gaussian_law(ssign)
        A2 = law_square(A)
        A2_d = iter_law_convolution(A2, d)

    fail_probability = tail_probability(A2_d, sqr_radius)
    fail = float(slog(fail_probability, 2))
    return fail


def forgeProbability(d, ssign, sver, ssec, A2_d1=None):
    """
    Determines the probability that the (weak) signature forgery attack works

    :param d:           an integer dimension
    :param ssign:       a standard deviation controlling the length of elements
                            sampling during signing
    :param sver:        a standard deviation controlling the length of
                            acceptable signatures
    :param ssec:        a standard deviation that describes the length of the
                            shortest vector discovered before key recovery
    :returns:           log2 of the (weak) forgery probability
    """
    sqr_radius = d * sver**2.
    flen = floor(d**.5 * ssec)
    flen_sqr = floor(d * ssec**2)

    A = centered_discrete_Gaussian_law(ssign)

    if A2_d1 is None:
        A2 = law_square(A)
        A2_d1 = iter_law_convolution(A2, d-1)

    Bonedim = {flen: 1}
    Conedim = law_convolution(A, Bonedim)
    C2onedim = law_square(Conedim)
    Donedim = law_convolution(A2_d1, C2onedim)

    onedimforge_probability = pos_head_probability(Donedim, sqr_radius)
    forgeonedim = float(slog(onedimforge_probability, 2))

    def diagonal_B(d, len_sqr):
        """
        Describe the entries of a vector with d entries, of square length
        close to, but bounded above by, len_sqr, and such that the sizes of
        the entries are as similar as possible

        :param d:       an integer dimension
        :param len_sqr: the square length that upper bounds the vector
        :returns:       a dictionary entries such that entries[x] = y means
                            the vector should have y entries with value x

        """
        assert d > 0 and d.is_integer(), "dimension should be a postive int"
        assert len_sqr > 0 and len_sqr.is_integer(), "len_sqr not +ve int"
        entries = {}
        entry_upper_bound = ceil((len_sqr / d)**.5)
        if entry_upper_bound == 1:
            entries[1.] = len_sqr
            entries[0.] = d - entries[1.]
        else:
            assert (len_sqr >= d)
            assert (len_sqr <= d*entry_upper_bound**2)

            upp = entry_upper_bound
            # solve: d_(upp-1)+d_upp=d
            # and  : (upp-1)^2 d_(upp-1) + upp^2 d_upp <= fixed_sqr_len
            # (up to rounding)
            dupp = floor((len_sqr - d*(upp-1)**2)/(2*upp-1))
            dupp1 = d - dupp

            assert (dupp+dupp1 == d)
            assert (dupp1*(upp-1)**2+dupp*upp**2 <= len_sqr)
            assert (dupp1*(upp-1)**2+dupp*upp**2 > len_sqr-upp**2)

            entries[upp-1] = dupp1
            entries[upp] = dupp
        return entries

    # calculate forge for B as ``diagonal`` as possible
    try:
        entries = diagonal_B(d, flen_sqr)

        distrs = []
        for (entry, conv) in entries.items():
            partial_diag = law_convolution(A, {entry: 1})
            partial_diag2 = law_square(partial_diag)
            partial_diag2c = iter_law_convolution(partial_diag2, conv)
            distrs += [partial_diag2c]

        C2diag = law_convolution(distrs[0], distrs[1])

        forgediag_probability = pos_head_probability(C2diag, sqr_radius)
        forgediag = float(slog(forgediag_probability, 2))

    except AssertionError:
        print('diagonal B failed to make a vector')

    forge = max(forgediag, forgeonedim)
    return forge


def dimensions_for_free(beta):
    """
    Apply the dimensions for free reduction to blocksize using the optimistic
    value from Sec 4.3 ePrint 2017/999

    :param beta:    an input blocksize
    :returns:       a smaller blocksize via dimensions for free techniques

    ..note::        this function is not automatically applied at the end of
                    findParams below
    """
    return beta - round(beta * log(4./3.) / log(beta / (2 * pi * e)))


def findParams(d, lam, q_s=2**64, betaKey=None, ssec=None):
    """
    A script to find parameters that satisfy our signature forgery
    cryptanalysis, and statistical requirements.

    :param d: an integer dimension = 2*n
    :param lam: security parameter for statistical arguments
    :param q_s: allowable signature queries for statistical arguments
    :param beta_key: beta required to recover secret key, if ``None``
            is calculated using BKZ_simulator
    :param ssec: sigma_sec from paper, if ``None`` calculated using
            BKZ_simulator

    :returns: dictionary of parameters and failure rates

    ..note: one must check the beta for signature forging and key recovery
            are sufficient, lam and q_s input parameters are solely for
            statistical arguments
    ..note: no dimensions for free applied here
    """
    ssign = statistical_ssign(d, lam, q_s)
    # The probability that the (weak) signature forgery attack works, should be
    # _at most_ 2^{-lambda}.
    forge_target = -lam
    # The probability that signing fails because x is too long, will be taken to
    # be _at least_ 1 / (q_s ** 2). If it would be even slightly smaller, taking
    # a smaller sver would only make the forge probability smaller (making
    # forgeries harder) while it would still be unlikely one will ever see some
    # x being too long during signing of q_s signatures.
    fail_target = -2 * log(q_s, 2)

    if betaKey is None or ssec is None:
        betaKey_, ssec_ = findBetaSsec(d, simulate=True, simulatessec=True)
        if betaKey is None:
            betaKey = int(betaKey_)
        if ssec is None:
            ssec = float(ssec_)

    assert ssec > ssign
    assert ssign > ssec / 2

    # precompute A2_d and A2_d1
    A = centered_discrete_Gaussian_law(ssign)
    A2 = law_square(A)
    A2_d1 = iter_law_convolution(A2, d-1)
    A2_d = law_convolution(A2_d1, A2)

    # Find, with a binary search, sver \in [ssign, ssec] such that the forge
    # probability is at most forge_target
    sver_lo = ssign
    sver_hi = ssec

    fail = failProbability(d, ssign, sver_lo, A2_d=A2_d)
    forge = forgeProbability(d, ssign, sver_lo, ssec, A2_d1=A2_d1)
    print(f"sver={sver_lo} gives a fail prob of 2^{fail} and forge prob of 2^{forge}.")
    if not (fail >= fail_target and forge <= forge_target):
        print('no parameters')
        return

    fail = failProbability(d, ssign, sver_hi, A2_d=A2_d)
    forge = forgeProbability(d, ssign, sver_hi, ssec, A2_d1=A2_d1)
    print(f"sver={sver_hi} gives a fail prob of 2^{fail} and forge prob of 2^{forge}.")
    if fail >= fail_target and forge <= forge_target:
        sver = sver_hi
    else:
        # Run a binary search
        for i in range(20):
            sver = 0.5 * (sver_lo + sver_hi)

            fail = failProbability(d, ssign, sver, A2_d=A2_d)
            forge = forgeProbability(d, ssign, sver, ssec, A2_d1=A2_d1)
            print(f"sver={sver} gives a fail prob of 2^{fail} and forge prob of 2^{forge}.")

            print(f"[{sver_lo}, {sver_hi}] => {fail >= fail_target} and {forge <= forge_target}")
            if fail >= fail_target and forge <= forge_target:
                # weak forgeries are hard enough for this value of sver
                sver_lo = sver
            else:
                # weak forgeries are too easy for this value of sver
                sver_hi = sver

        # The final verification sigma is chosen as the largest (tested) value
        # that has a small enough forge probability.
        sver = sver_lo

    print("checking everything")
    fail = failProbability(d, ssign, sver, A2_d=A2_d)
    forge = forgeProbability(d, ssign, sver, ssec, A2_d1=A2_d1)
    betaForge = approx_SVP_beta(d, sver=sver)

    assert ssign <= sver
    assert sver <= ssec
    assert fail >= fail_target
    assert forge <= forge_target

    print("Dim, lambda, log2(q_s):", d, lam, log(q_s, 2).n())
    print("key recovery beta:", betaKey)
    print("forging beta     :", betaForge)
    print("s{sign, sec, ver}:", ssign, ssec, sver)
    print("log2(p_sig_fail) :", fail)
    print("log2(p_sig_forge):", forge)
    print()

    params = {}
    params['betaKey'] = betaKey
    params['betaForge'] = betaForge
    params['ssign'] = ssign
    params['ssec'] = ssec
    params['sver'] = sver
    params['fail'] = fail
    params['forge'] = forge

    return params


# Find HAWK parameters from scratch.
# This takes ~3hours on a decent CPU.
"""
findParams(512, 64, q_s=2**32)
# output: s{sign, sec, ver}: 1.00912944750969 1.0415240265983814 1.0415240265983814
findParams(1024, 128, q_s=2**64)
# output: s{sign, sec, ver}: 1.27783369691283 1.4252478209310997 1.4252478209310997
findParams(2048, 256, q_s=2**64)
# output: s{sign, sec, ver}: 1.29828033434429 1.9740905690067685 1.57138068874436
"""

# Find HAWK parameters with betaKey and ssec precomputed:
"""
findParams(512, 64, q_s=2**32, betaKey=211, ssec=1.042)
# output: {sign, sec, ver}: 1.00912944750969 1.04200000000000 1.04200000000000
findParams(1024, 128, q_s=2**64, betaKey=452, ssec=1.425)
# output: s{sign, sec, ver}: 1.27783369691283 1.42500000000000 1.42500000000000
findParams(2048, 256, q_s=2**64, betaKey=940, ssec=1.974)
# output: s{sign, sec, ver}: 1.29828033434429 1.97400000000000 1.57138082081982
"""
