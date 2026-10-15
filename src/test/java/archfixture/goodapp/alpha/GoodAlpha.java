package archfixture.goodapp.alpha;

import archfixture.goodapp.beta.GoodBeta;

/** Depends on module beta one way only. */
public class GoodAlpha {
    GoodBeta beta;
}
