package archfixture.bad.application.port;

import org.springframework.http.ResponseEntity;

/** Violates H-03 (HTTP type in a port signature). */
public interface BadPort {
    ResponseEntity<String> find();
}
