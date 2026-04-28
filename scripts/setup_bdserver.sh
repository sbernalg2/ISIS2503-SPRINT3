#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y default-jre-headless wget curl

# Instalar JMeter 5.6.3
wget -q https://downloads.apache.org/jmeter/binaries/apache-jmeter-5.6.3.tgz \
     -O /tmp/jmeter.tgz
tar -xzf /tmp/jmeter.tgz -C /opt/
ln -sf /opt/apache-jmeter-5.6.3/bin/jmeter /usr/local/bin/jmeter

# Plan ASR-2: 5000 usuarios GET /report/<N>/
cat > /opt/asr_latencia.jmx << 'JMXEOF'
<?xml version="1.0" encoding="UTF-8"?>
<jmeterTestPlan version="1.2" properties="5.0">
  <hashTree>
    <TestPlan guiclass="TestPlanGui" testclass="TestPlan" testname="OptiCloud ASR-LAT">
      <hashTree>
        <ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup"
                     testname="5000 Usuarios Sostenidos">
          <intProp name="ThreadGroup.num_threads">5000</intProp>
          <intProp name="ThreadGroup.ramp_time">60</intProp>
          <intProp name="ThreadGroup.duration">120</intProp>
          <boolProp name="ThreadGroup.scheduler">true</boolProp>
          <hashTree>
            <HTTPSamplerProxy testname="GET /report/ ASR-LAT">
              <stringProp name="HTTPSampler.domain">ALB_DNS_HERE</stringProp>
              <intProp name="HTTPSampler.port">80</intProp>
              <stringProp name="HTTPSampler.path">/report/$${__Random(1,100)}/</stringProp>
              <stringProp name="HTTPSampler.method">GET</stringProp>
              <hashTree/>
            </HTTPSamplerProxy>
            <ResultCollector testname="Results">
              <stringProp name="filename">/opt/resultados_asr_lat.jtl</stringProp>
              <hashTree/>
            </ResultCollector>
          </hashTree>
        </ThreadGroup>
      </hashTree>
    </TestPlan>
  </hashTree>
</jmeterTestPlan>
JMXEOF

# Plan ASR-1: 12000 usuarios POST /enqueue/
cat > /opt/asr_escalabilidad.jmx << 'JMXEOF'
<?xml version="1.0" encoding="UTF-8"?>
<jmeterTestPlan version="1.2" properties="5.0">
  <hashTree>
    <TestPlan guiclass="TestPlanGui" testclass="TestPlan" testname="OptiCloud ASR-1">
      <hashTree>
        <ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup"
                     testname="12000 Usuarios Pico">
          <intProp name="ThreadGroup.num_threads">12000</intProp>
          <intProp name="ThreadGroup.ramp_time">120</intProp>
          <intProp name="ThreadGroup.duration">600</intProp>
          <boolProp name="ThreadGroup.scheduler">true</boolProp>
          <hashTree>
            <HTTPSamplerProxy testname="POST /enqueue/ ASR-1">
              <stringProp name="HTTPSampler.domain">ALB_DNS_HERE</stringProp>
              <intProp name="HTTPSampler.port">80</intProp>
              <stringProp name="HTTPSampler.path">/enqueue/</stringProp>
              <stringProp name="HTTPSampler.method">POST</stringProp>
              <boolProp name="HTTPSampler.postBodyRaw">true</boolProp>
              <elementProp name="HTTPsampler.Arguments" elementType="Arguments">
                <collectionProp name="Arguments.arguments">
                  <elementProp name="" elementType="HTTPArgument">
                    <stringProp name="Argument.value">{"client_id": $${__Random(1,1000)}}</stringProp>
                  </elementProp>
                </collectionProp>
              </elementProp>
              <hashTree/>
            </HTTPSamplerProxy>
            <ResultCollector testname="Results">
              <stringProp name="filename">/opt/resultados_asr1.jtl</stringProp>
              <hashTree/>
            </ResultCollector>
          </hashTree>
        </ThreadGroup>
      </hashTree>
    </TestPlan>
  </hashTree>
</jmeterTestPlan>
JMXEOF

# Script helper para configurar y lanzar pruebas
cat > /opt/correr_pruebas.sh << 'SHEOF'
#!/bin/bash
ALB=$1
if [ -z "$ALB" ]; then
  echo "Uso: bash /opt/correr_pruebas.sh <ALB_DNS>"
  exit 1
fi
sed -i "s/ALB_DNS_HERE/$ALB/g" /opt/asr_latencia.jmx
sed -i "s/ALB_DNS_HERE/$ALB/g" /opt/asr_escalabilidad.jmx
echo "Planes JMeter actualizados con ALB: $ALB"
echo ""
echo "ASR-2 Latencia (5000 usuarios):"
echo "  jmeter -n -t /opt/asr_latencia.jmx -l /opt/resultados_asr_lat.jtl"
echo ""
echo "ASR-1 Escalabilidad (12000 usuarios):"
echo "  jmeter -n -t /opt/asr_escalabilidad.jmx -l /opt/resultados_asr1.jtl"
SHEOF
chmod +x /opt/correr_pruebas.sh
echo "BD Server listo. JMeter en /usr/local/bin/jmeter"