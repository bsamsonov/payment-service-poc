package archfixture.bad.application;

import archfixture.bad.adapter.in.web.api.BadApi;
import archfixture.bad.adapter.out.persistence.BadEntity;
import archfixture.bad.config.BadConfig;
import archfixture.bad.domain.BadDomain;

/** Violates H-02 (adapter and config types in a use case), H-07 (generated API type), H-11 (config). */
public class BadUseCase {
    BadEntity entity;
    BadApi api;
    BadConfig config;
    BadDomain domain;
}
