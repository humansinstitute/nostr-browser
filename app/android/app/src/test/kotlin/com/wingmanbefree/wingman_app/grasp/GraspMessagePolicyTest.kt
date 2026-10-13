package com.wingmanbefree.wingman_app.grasp

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GraspMessagePolicyTest {
    @Test fun `grasp accepts only the HTTPS current main frame`() {
        assertTrue(GraspMessagePolicy.accepts("WingmanGrasp", true, "https://app.example", "https://app.example/path"))
        assertTrue(GraspMessagePolicy.accepts("WingmanGrasp", true, "https://app.example:443", "https://app.example/path"))
        assertFalse(GraspMessagePolicy.accepts("WingmanGrasp", false, "https://app.example", "https://app.example"))
        assertFalse(GraspMessagePolicy.accepts("WingmanGrasp", true, "https://evil.example", "https://app.example"))
        assertFalse(GraspMessagePolicy.accepts("WingmanGrasp", true, "https://app.example:444", "https://app.example"))
        assertFalse(GraspMessagePolicy.accepts("WingmanGrasp", true, "https://app.example", "http://app.example"))
        assertFalse(GraspMessagePolicy.accepts("WingmanGrasp", true, "http://app.example", "http://app.example"))
    }

    @Test fun `bundled Flight Deck is exact port and main frame only`() {
        assertTrue(GraspMessagePolicy.accepts("WingmanGrasp", true, "http://127.0.0.1:47831", "http://127.0.0.1:47831/drive"))
        assertFalse(GraspMessagePolicy.accepts("WingmanGrasp", false, "http://127.0.0.1:47831", "http://127.0.0.1:47831/drive"))
        assertFalse(GraspMessagePolicy.accepts("WingmanGrasp", true, "http://127.0.0.1:47832", "http://127.0.0.1:47832/drive"))
    }

    @Test fun `signer rejects iframe spoofing but preserves HTTP top frames`() {
        assertTrue(GraspMessagePolicy.accepts("WingmanSigner", true, "http://localhost:8080", "http://localhost:8080/app"))
        assertFalse(GraspMessagePolicy.accepts("WingmanSigner", false, "https://app.example", "https://app.example"))
        assertFalse(GraspMessagePolicy.accepts("WingmanSigner", true, "https://evil.example", "https://app.example"))
        assertFalse(GraspMessagePolicy.accepts("WingmanTower", true, "https://app.example", "https://app.example"))
    }

    @Test fun `opaque malformed credentialed and missing origins fail closed`() {
        for (url in listOf("null", "about:blank", "file:///app", "data:text/html,test", "https://user@app.example", "https://app.example:99999", "")) {
            assertFalse(url, GraspMessagePolicy.accepts("WingmanGrasp", true, url, url))
        }
        assertFalse(GraspMessagePolicy.accepts("WingmanGrasp", true, "https://app.example", null))
        assertFalse(GraspMessagePolicy.accepts("Unknown", true, "https://app.example", "https://app.example"))
    }
}
