# JNI exports encode this class name; Rust also calls the resolver by name and
# descriptor ([BJ)[B. Neither boundary is visible to R8's Java call graph.
-keep,allowoptimization class com.wingmanbefree.wingman_app.fips.FipsNative {
    native <methods>;
    public static byte[] resolvePublicDns(byte[], long);
}
