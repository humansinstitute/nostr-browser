package com.wingmanbefree.wingman_app.grasp

import org.junit.Assert.*
import org.junit.Test

class NativeHomeHtmlPolicyTest {
    @Test fun nativeHomeHasSeparateBound() {
        assertEquals(1_500_000, GraspMessagePolicy.MAX_MESSAGE_LENGTH)
        assertTrue(NativeHomeHtmlPolicy.accepts("x".repeat(2_300_000)))
        assertTrue(NativeHomeHtmlPolicy.accepts("x".repeat(NativeHomeHtmlPolicy.MAX_HTML_LENGTH)))
        assertFalse(NativeHomeHtmlPolicy.accepts("x".repeat(NativeHomeHtmlPolicy.MAX_HTML_LENGTH + 1)))
    }
}
