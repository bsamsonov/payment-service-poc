package io.github.bsamsonov.paymentservice.adapter.in.web;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.github.bsamsonov.paymentservice.adapter.in.web.model.CreatePaymentRequest;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.json.JsonTest;
import tools.jackson.databind.DatabindException;
import tools.jackson.databind.json.JsonMapper;

/**
 * The application's Jackson settings ({@code spring.jackson.*}) must reject request bodies instead of coercing them: a
 * money amount is never truncated or parsed from a string. Runs without a database.
 */
@JsonTest
class JacksonStrictnessTest {

    private static final String VALID_FIELDS =
            "\"currency\":\"USD\",\"paymentMethodId\":\"pm_card_visa\",\"externalReference\":\"order-1\"";

    @Autowired
    private JsonMapper jsonMapper;

    @Test
    @DisplayName("an integer amount in minor units is accepted")
    void acceptsIntegerAmount() {
        CreatePaymentRequest request = read("{\"amount\":1999," + VALID_FIELDS + "}");

        assertThat(request.getAmount()).isEqualTo(1999L);
    }

    @ParameterizedTest(name = "amount {0}")
    @ValueSource(strings = {"19.99", "1999.0", "1.999e3", "\"1999\""})
    @DisplayName("a fractional, exponent or string amount is rejected, not coerced")
    void rejectsNonIntegerAmount(String amount) {
        assertThatThrownBy(() -> read("{\"amount\":" + amount + "," + VALID_FIELDS + "}"))
                .isInstanceOf(DatabindException.class);
    }

    @Test
    @DisplayName("an unknown field is rejected")
    void rejectsUnknownField() {
        assertThatThrownBy(() -> read("{\"amount\":1999," + VALID_FIELDS + ",\"captureMethod\":\"manual\"}"))
                .isInstanceOf(DatabindException.class);
    }

    private CreatePaymentRequest read(String json) {
        return jsonMapper.readValue(json, CreatePaymentRequest.class);
    }
}
