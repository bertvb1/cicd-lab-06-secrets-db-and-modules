# jar-files/jar/

Library JARs that belong on the gateway classpath (`lib/core/gateway/`). They
load at **boot**, like modules — so the deploy step you add in Stretch S4
copies changed JARs into the container and restarts the gateway only when one
actually changed.

Pin exact versions and record where every JAR came from:

| JAR | Source | Checksum (sha256) |
|---|---|---|
| `commons-csv-1.14.1.jar` | [Maven Central](https://repo1.maven.org/maven2/org/apache/commons/commons-csv/1.14.1/commons-csv-1.14.1.jar) | `32be0e1e76673092f5d12cb790bd2acb6c2ab04c4ea6efc69ea5ee17911c24fe` |

Use it from any gateway-scoped script (Perspective bindings and transforms run
on the gateway, so the gateway classpath is the one that counts):

```python
from org.apache.commons.csv import CSVFormat
from java.io import StringReader
records = CSVFormat.DEFAULT.parse(StringReader("pump,3,ok")).getRecords()
fields = list(records[0])   # -> ["pump", "3", "ok"]
```

Why commons-csv and not, say, commons-lang3: the Ignition image already
bundles `commons-lang3` (and `commons-text`, `commons-io`, `guava`, …) under
`lib/core/common/`, so importing those succeeds without you shipping
anything — no good for proving your JAR arrived. `commons-csv` is **not**
bundled: the import genuinely fails until the pipeline puts this file on the
classpath.

The gateway has no package manager: this folder plus this table **is** the
lockfile. A JAR nobody can re-download and verify is a JAR you can't trust.
