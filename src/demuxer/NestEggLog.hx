package demuxer;

enum abstract NestEggLog(Int) from Int to Int {
	final NESTEGG_LOG_DEBUG = 1; /**< Debug level log message. */

	final NESTEGG_LOG_INFO = 10; /**< Informational level log message. */

	final NESTEGG_LOG_WARNING = 100; /**< Warning level log message. */

	final NESTEGG_LOG_ERROR = 1000; /**< Error level log message. */

	final NESTEGG_LOG_CRITICAL = 10000; /**< Critical level log message. */

}
